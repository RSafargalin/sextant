import Foundation
import Testing
@testable import SextantCore

@Suite("Shell commands")
struct ShellCommandTests {
    private func words(_ line: String) -> [[String]] {
        ShellCommand.commands(in: line).map(\.words)
    }

    @Test("A line is split into the commands it runs")
    func splitsOnOperators() {
        #expect(words("cd /p && grep -rn Store . ; ls") == [["cd", "/p"], ["grep", "-rn", "Store", "."], ["ls"]])
        #expect(words("a || b & c") == [["a"], ["b"], ["c"]])
        #expect(words("echo $(grep x f) `rg y`") == [["echo"], ["grep", "x", "f"], ["rg", "y"]])
        #expect(words("(cd /p; grep x)") == [["cd", "/p"], ["grep", "x"]])
        #expect(words("a\nb") == [["a"], ["b"]])
    }

    @Test("Quotes, escapes and redirections stay inside their command")
    func keepsQuotedText() {
        #expect(words("git commit -m \"fix | grep && sextant\"") == [["git", "commit", "-m", "fix | grep && sextant"]])
        #expect(words("echo 'a;b' \"c\\\"d\"") == [["echo", "a;b", "c\"d"]])
        #expect(words("swift build 2>&1 | tail") == [["swift", "build"], ["tail"]])
        #expect(words("make &> log") == [["make"]])
        #expect(words("echo a>b c") == [["echo", "a", "c"]])
        // In double quotes a backslash escapes only `$`, a backtick, `"`, `\` and a newline.
        #expect(words(#"rg "\bFoo\b" '\d'"#) == [["rg", #"\bFoo\b"#, #"\d"#]])
        #expect(words("grep \\\n  -rn Store .") == [["grep", "-rn", "Store", "."]])
    }

    @Test("Output sent to a file is told apart from output that comes back")
    func marksFileOutput() {
        let writes = { (line: String) in ShellCommand.commands(in: line).map(\.writesFile) }
        #expect(writes("cat > A.swift <<'EOF'\nx\nEOF") == [true])
        #expect(writes("cat A.swift >> all.txt") == [true])
        #expect(writes("swift build &> log") == [true])
        #expect(writes("swift build 2>&1") == [false])
        #expect(writes("swift build 2> errors") == [false])
        #expect(writes("cat A.swift >&2") == [false])
    }

    @Test("A pipe makes the next command read the previous one's output")
    func marksPipes() {
        let commands = ShellCommand.commands(in: "swift build 2>&1 | grep error && grep -rn Store .")
        #expect(commands.map(\.readsPipe) == [false, true, false])
        #expect(ShellCommand.commands(in: "a |& b").map(\.readsPipe) == [false, true])
    }

    @Test("A comment and a heredoc body are not commands")
    func dropsCommentsAndHeredocs() {
        #expect(words("# grep for it\nswift build") == [["swift", "build"]])
        #expect(words("echo a#b") == [["echo", "a#b"]])
        let script = "python3 - <<'EOF'\ngrep = 1\nsextant refs X\nEOF\nswift test"
        #expect(words(script) == [["python3", "-"], ["swift", "test"]])
        let tabbed = "cat <<-END > f\n\tgrep x\n\tEND\nls"
        #expect(words(tabbed) == [["cat"], ["ls"]])
        #expect(words("cat <<END-OF-TEXT\ngrep x\nEND-OF-TEXT\ngrep -rn Foo .") == [["cat"], ["grep", "-rn", "Foo", "."]])
        #expect(words("cat <<\\EOF\ngrep x\nEOF\nls") == [["cat"], ["ls"]])
        // A `<<` inside quotes is not a heredoc, and a here-string opens none.
        #expect(words("python3 -c \"print(1 << n)\"\ngrep -rn Foo .") == [["python3", "-c", "print(1 << n)"], ["grep", "-rn", "Foo", "."]])
        #expect(words("grep x <<< \"$v\"\nls") == [["grep", "x"], ["ls"]])
    }
}

@Suite("Navigation acts — what a line actually runs")
struct NavigationInvocationTests {
    private func act(_ command: String) -> NavigationAct {
        NavigationAct.of(tool: "Bash", command: command)
    }

    /// Two months of the first log format: 239 of 640 "calls" were commands that only mentioned a
    /// path with `sextant` in it — `cd ~/Tools/sextant && git log` — mostly from working on sextant.
    @Test("A path containing sextant is not a call to it")
    func pathIsNotACall() {
        #expect(act("cd ~/Documents/Claude/Tools/sextant && git log --oneline") == .other)
        #expect(act("ls -la /usr/local/bin/sextant") == .other)
        #expect(act("which sextant") == .other)
        #expect(act("git commit -m \"sextant refs fix\"") == .other)
        #expect(act("cd /work/sextant && grep -rn Store .") == .textSearch)
    }

    @Test("Help, version, setup and the metric itself are not navigation")
    func setupIsNotNavigation() {
        for line in ["sextant", "sextant --help", "sextant --version", "sextant hook --install", "sextant init",
                     "sextant index --project .", "sextant adoption", "sextant doctor", "sextant mcp", "sextant serve"] {
            #expect(act(line) == .other, "\(line) is not a question about code")
        }
    }

    @Test("A real call counts however it is launched")
    func realCalls() {
        for line in ["sextant refs Store", "/usr/local/bin/sextant search 'try? $X.save()'",
                     "./.build/debug/sextant context Store", "SEXTANT_NO_DAEMON=1 sextant defs Store",
                     "timeout 30 sextant api --package Core", "env -u X FOO=1 sextant map",
                     "cd /p && sextant body Store", "nohup sextant map", "time sextant callers save"] {
            #expect(act(line) == .sextant, "\(line) runs sextant")
        }
    }

    /// 4 878 of 17 285 shell lines the first format counted as searches only filtered another
    /// command's output: `swift build | grep`, `xcrun … | grep`, `ps | grep`.
    @Test("A search downstream of a pipe filters output, and is not a search of the sources")
    func pipeFilterIsNotASearch() {
        #expect(act("swift build 2>&1 | grep -E 'error|warning'") == .other)
        #expect(act("xcrun simctl list | grep Booted") == .other)
        #expect(act("git log --oneline | grep fix") == .other)
        #expect(act("grep -rn Store Sources | head -20") == .textSearch)
        #expect(act("find . -name '*.swift' | xargs grep -l Store") == .textSearch)
        #expect(NavigationAct.searchPattern(inShellCommand: "find . -name '*.swift' | xargs -0 grep -l Store") == "Store")
    }

    @Test("Our answer narrowed by grep is our answer")
    func narrowedAnswer() {
        #expect(act("sextant api --package Core | grep save") == .sextant)
        #expect(act("grep -rn Store . && sextant refs Store") == .sextant)
    }

    /// Reading through `Bash` is as common as the `Read` tool in agent sessions; leaving it out
    /// halved the reads in the denominator, and pushing agents off grep could move them onto `sed -n`
    /// with the metric reporting a gain that never happened.
    @Test("A source file printed through the shell is a read, like the Read tool")
    func shellReads() {
        #expect(act("sed -n '40,90p' Sources/Core/Store.swift") == .fileRead)
        #expect(act("cd /p && cat Sources/A.swift") == .fileRead)
        #expect(act("head -50 /p/B.m") == .fileRead)
        #expect(act("cat README.md") == .other)
        #expect(act("sed -i '' 's/a/b/' Sources/A.swift") == .other)        // an edit, not a read
        #expect(act("git show HEAD:Sources/A.swift | head") == .other)
        #expect(act("cat Sources/A.swift | grep save") == .textSearch)      // a search of that file
        #expect(act("cat > Sources/A.swift <<'EOF'\nlet x = 1\nEOF") == .other)  // a write
        #expect(act("cat A.swift B.swift > all.txt") == .other)
        #expect(act("sed --in-place=.bak 's/a/b/' A.swift") == .other)
        #expect(act("grep -n save Sources/A.swift && cat Sources/A.swift") == .textSearch)
    }

    @Test("One classification serves the hook and the transcript reader alike")
    func classifiesEvents() {
        let search = NavigationAct.events(tool: "Bash", input: ["command": "cd /p && grep -rn saveAll Sources/"])
        #expect(search == [NavigationEvent(act: .textSearch, shape: .identifier, searched: "saveAll", channel: nil,
                                           project: "/p")])
        let cli = NavigationAct.events(tool: "Bash", input: ["command": "timeout 60 sextant refs Store"])
        // A command line is not a query: no shape is made of it.
        #expect(cli == [NavigationEvent(act: .sextant, shape: nil, searched: nil, channel: .cli)])
        let mcp = NavigationAct.events(tool: "mcp__sextant__structural_search", input: ["pattern": "try? $X.save()"])
        #expect(mcp == [NavigationEvent(act: .sextant, shape: .pattern, searched: nil, channel: .mcp)])
        let read = NavigationAct.events(tool: "Bash", input: ["command": "sed -n 1,20p Sources/A.swift"])
        #expect(read == [NavigationEvent(act: .fileRead, shape: .path, searched: nil, channel: nil)])
        #expect(NavigationAct.events(tool: "Edit", input: ["file_path": "/p/A.swift"]).isEmpty)
        #expect(NavigationAct.events(tool: "Bash", input: ["command": "swift build"]).isEmpty)
    }

    /// In real sessions 19 % of the lines that ask sextant also grep the sources — usually to check
    /// the answer. Counted as one sextant act, the search vanished from the denominator and the
    /// check from sight.
    @Test("A call that asks sextant and searches past it is both, and the answer is marked checked")
    func severalActsInOneCall() {
        let events = NavigationAct.events(tool: "Bash", input: [
            "command": "sextant search TagFilter | head; grep -rn \"struct TagFilter\" Sources/"])
        #expect(events.map(\.act) == [.sextant, .textSearch])
        #expect(events.first?.crossChecked == true)
        #expect(events.last?.searched == "struct TagFilter")

        // Narrowing our own answer is not a search past it.
        let narrowed = NavigationAct.events(tool: "Bash", input: ["command": "sextant api --package Core | grep save"])
        #expect(narrowed.map(\.act) == [.sextant])
        #expect(narrowed.first?.crossChecked == false)

        // Each kind once, in the order the line ran them.
        let mixed = NavigationAct.events(tool: "Bash", input: [
            "command": "grep -n save A.swift && cat A.swift && grep -rn load Sources && sextant refs save"])
        #expect(mixed.map(\.act) == [.textSearch, .fileRead, .sextant])

        // A read feeding a search is the search only.
        #expect(NavigationAct.events(tool: "Bash", input: ["command": "cat A.swift | grep save"]).map(\.act) == [.textSearch])
    }

    @Test("A sextant call names the project it was asked about")
    func namesTheProject() {
        let events = NavigationAct.events(tool: "Bash", input: [
            "command": ".build/debug/sextant refs Store --project Tests/Fixtures/IndexFixture"])
        #expect(events.first?.project == "Tests/Fixtures/IndexFixture")
        #expect(NavigationAct.events(tool: "Bash", input: ["command": "sextant map --project=/x"]).first?.project == "/x")
        #expect(NavigationAct.events(tool: "Bash", input: ["command": "sextant map"]).first?.project == nil)

        // The directory a call is about is the one the line moved to, by `cd`, `--project`, or both.
        let project = { (command: String) in NavigationAct.events(tool: "Bash", input: ["command": command]).first?.project }
        #expect(project("cd ~/tea && sextant refs Y --project .") == "~/tea/.")
        #expect(project("cd ~/tea && sextant refs Y") == "~/tea")
        #expect(project("R=~/tea; sextant refs Z --project $R") == "~/tea")
        #expect(project("cd /a && cd b && sextant refs Z") == "/a/b")
        #expect(project("cd /a && sextant refs Z --project /x") == "/x")
        #expect(project("SP=/tmp/s; sextant search X --project $SP/sdwebimage") == "/tmp/s/sdwebimage")
        #expect(project("SP=/tmp/s; cd ${SP}/x && sextant refs Z --project $SP/x") == "/tmp/s/x")
        #expect(project("sextant refs Z --project $UNKNOWN/x") == "$UNKNOWN/x")       // left as written
        #expect(project("cd /a && cd - && sextant refs Z") == "/a")                    // `cd -` is unknown

        // A search or a read is about the directory it ran in, as sextant is.
        let acts = NavigationAct.events(tool: "Bash", input: ["command":
            "grep -rn A Sources && cd ~/other && grep -rn B Sources && cat A.swift && sextant refs C --project /x"])
        #expect(acts.map(\.act) == [.textSearch, .fileRead, .sextant])
        #expect(acts.map(\.project) == [nil, "~/other", "/x"])
    }

    @Test("A command inside a loop, a condition or a group is still the command")
    func compoundCommands() {
        #expect(act("for f in *.swift; do grep -n Foo \"$f\"; done") == .textSearch)
        #expect(act("if grep -q Foo a.swift; then echo yes; fi") == .textSearch)
        #expect(act("{ grep -rn Foo .; } 2>&1") == .textSearch)
        #expect(act("! grep -q Foo a.swift") == .textSearch)
        #expect(act("for s in A B; do sextant refs $s; done") == .sextant)
        #expect(act("while read f; do echo $f; done") == .other)
    }

    @Test("find -exec grep searches the files find walks")
    func findExec() {
        #expect(act("find Sources -name '*.swift' -exec grep -n Foo {} \\;") == .textSearch)
        #expect(NavigationAct.searchPattern(inShellCommand: "find . -type f -exec rg -l Store {} +") == "Store")
        #expect(act("find . -name '*.o' -exec rm {} \\;") == .other)
    }

    @Test("A pipe fed by the sources or a list of them is a search, any other pipe a filter")
    func pipeSources() {
        #expect(act("git ls-files | grep Store") == .textSearch)
        #expect(act("rg --files | grep -i store") == .textSearch)
        #expect(act("cat README.md | grep x") == .other)
    }

    @Test("Looking a program up is not running it, and sudo or nice still run it")
    func wrappers() {
        #expect(act("command -v rg") == .other)
        #expect(act("command -V grep") == .other)
        #expect(act("command grep -rn Foo .") == .textSearch)
        #expect(act("sudo grep -rn Foo /etc") == .textSearch)
        #expect(act("nice -n 5 rg Foo") == .textSearch)
    }

    /// Every one of these used to come back as a flag's value, and a value such as `swift` is an
    /// identifier — inflating exactly the residue the report points at `defs` and `refs`.
    @Test("The pattern is found past the flags that take a value")
    func patternPastFlags() {
        let cases = [
            "rg --type swift Foo": "Foo", "rg -t swift 'a.b'": "a.b", "rg -j 4 Foo": "Foo",
            "rg --max-depth 2 Foo .": "Foo", "rg -r X Foo": "Foo", "rg -E utf8 Foo": "Foo",
            "grep -rn --exclude-dir .build Foo .": "Foo", "grep -rnE -- '-Foo' .": "-Foo",
            "grep -E 'a|b' x.swift": "a|b", "grep -r Foo .": "Foo", "grep -d skip Foo *": "Foo",
        ]
        for (command, pattern) in cases {
            #expect(NavigationAct.searchPattern(inShellCommand: command) == pattern, "\(command)")
        }
        // A pattern read from a file is not known, and is not guessed.
        #expect(NavigationAct.searchPattern(inShellCommand: "grep -f patterns.txt -r .") == nil)
    }

    /// Searching a design doc or a log is not what sextant replaces, the same way a `Read` of a
    /// README is not counted; both used to weigh in the denominator on one side only.
    @Test("A search of documents and logs is not a search of the sources")
    func nonSourceSearches() {
        #expect(act("grep -n Store docs/design.md") == .other)
        #expect(act("until grep -q EXIT= /tmp/run.log; do sleep 1; done") == .other)
        #expect(act("rg -g '*.md' Store") == .other)
        #expect(act("grep -rn --include='*.json' Store .") == .other)
        #expect(act("grep -n Store Sources/A.swift docs/a.md") == .textSearch)
        #expect(act("rg -g '*.{h,m}' Store") == .textSearch)
        #expect(act("rg --glob '*.{md,txt}' Store") == .other)
        #expect(act("grep -rn Store Sources") == .textSearch)
        #expect(act("egrep -rn 'a|b' .") == .textSearch)
        #expect(NavigationAct.searchPattern(inShellCommand: #"rg "\bFoo\b" Sources"#) == #"\bFoo\b"#)
    }

    @Test("A target held in a variable is judged by its value")
    func variableTargets() {
        #expect(act("L=/tmp/run.log; until grep -q EXIT= $L; do sleep 15; done") == .other)
        #expect(act("for f in docs/a.md docs/b.md; do grep -n Store \"$f\"; done") == .other)
        #expect(act("D=docs; grep -n Store $D/design.md") == .other)
        #expect(act("for f in Sources/*.swift; do grep -n Store \"$f\"; done") == .textSearch)
        #expect(act("grep -n Store \"$UNKNOWN\"") == .textSearch)       // nothing known: the sources
        #expect(NavigationAct.searchPattern(inShellCommand: "grep --regexp=Foo Sources") == "Foo")
    }

    @Test("Help for a navigation command is not navigation")
    func commandHelp() {
        #expect(act("sextant search --help") == .other)
        #expect(act("sextant api -h; sextant refs --help") == .other)
        #expect(act("sextant search --help; sextant refs Store") == .sextant)
    }

    @Test("The Grep and Glob tools are held to the rule of their shell counterparts")
    func searchToolTargets() {
        let event = { (tool: String, input: [String: Any]) in
            NavigationAct.events(tool: tool, input: input).first?.act ?? .other
        }
        #expect(event("Grep", ["pattern": "Store", "glob": "*.md"]) == .other)
        #expect(event("Grep", ["pattern": "Store", "path": "docs/a.md"]) == .other)
        #expect(event("Grep", ["pattern": "Store", "type": "md"]) == .other)
        #expect(event("Grep", ["pattern": "Store", "type": "swift"]) == .textSearch)
        #expect(event("Grep", ["pattern": "Store", "path": "Sources"]) == .textSearch)
        #expect(event("Grep", ["pattern": "Store"]) == .textSearch)
        #expect(event("Glob", ["pattern": "**/*.md"]) == .other)
        #expect(event("Glob", ["pattern": "Sources/**/*.swift"]) == .textSearch)
    }

    @Test("git grep is a search of the sources")
    func gitGrep() {
        #expect(act("git grep -n Store") == .textSearch)
        #expect(act("git -C /p grep Store -- '*.swift'") == .textSearch)
        #expect(NavigationAct.searchPattern(inShellCommand: "git -C /p grep -n Store") == "Store")
        #expect(act("git log --grep fix") == .other)
    }

    @Test("A script in a heredoc is not run by the shell")
    func heredocIsData() {
        #expect(act("python3 - <<'EOF'\nimport os\nos.system('sextant refs X')\ngrep = 1\nEOF") == .other)
    }

    @Test("Commands that answer a question about code are the navigation commands")
    func navigationCommands() {
        let commands = CommandCatalog.navigationCommands
        for name in ["map", "api", "search", "changed", "refs", "defs", "callers", "impls", "context", "body"] {
            #expect(commands.contains(name), "\(name) answers a question about code")
        }
        for name in ["index", "lint", "init", "mcp", "serve", "store", "doctor", "golden", "bench", "adoption", "hook", "completion"] {
            #expect(!commands.contains(name), "\(name) is not navigation")
        }
    }
}

@Suite("Navigation channel")
struct NavigationChannelTests {
    @Test("An MCP tool of sextant is recognised however the server was registered")
    func recognisesServers() {
        #expect(NavigationAct.of(tool: "mcp__sextant__context", command: nil) == .sextant)
        // A plugin-bundled server: mcp__plugin_<plugin>_<server>__<tool>.
        #expect(NavigationAct.of(tool: "mcp__plugin_sextant_sextant__find_references", command: nil) == .sextant)
        #expect(NavigationAct.of(tool: "mcp__sextant-horngate__body", command: nil) == .sextant)
        #expect(NavigationAct.of(tool: "mcp__other__grep", command: nil) == .other)
        #expect(NavigationAct.of(tool: "mcp__plugin_tools_search__sextant", command: nil) == .other)
        #expect(NavigationAct.of(tool: "mcp__sextantish__context", command: nil) == .other)
        // Linting judges the code rather than finding anything in it, by either channel.
        #expect(NavigationAct.of(tool: "mcp__sextant__lint", command: nil) == .other)
    }

    @Test("A sextant answer says whether it came over MCP or the command line")
    func tellsChannelsApart() {
        #expect(NavigationAct.channel(ofTool: "mcp__sextant__api") == .mcp)
        #expect(NavigationAct.channel(ofTool: "mcp__plugin_sextant_sextant__api") == .mcp)
        #expect(NavigationAct.channel(ofTool: "Bash") == .cli)
    }
}

/// A git repository with one linked worktree, made with git itself.
struct TemporaryRepository {
    let root: URL
    let worktree: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-repo-\(UUID().uuidString)")
        root = base.appendingPathComponent("main")
        worktree = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Core"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "README"],
                          ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"],
                          ["worktree", "add", "-q", worktree.path]] {
            guard Command.git(arguments, in: root.path) != nil else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "git \(arguments) failed"])
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

@Suite("Repository root")
struct RepositoryRootTests {
    private func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test("A subdirectory and a linked worktree resolve to the main working tree")
    func resolvesWorktrees() throws {
        let repository = try TemporaryRepository()
        defer { repository.remove() }
        let main = canonical(repository.root)
        #expect(RepositoryRoot.of(repository.root.path) == main)
        #expect(RepositoryRoot.of(repository.root.appendingPathComponent("Sources/Core").path) == main)
        #expect(RepositoryRoot.of(repository.worktree.path) == main)
    }

    @Test("A submodule is its own project, and a directory outside git is its own root")
    func submoduleAndPlainDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-sub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let modules = base.appendingPathComponent("super/.git/modules/sub")
        let submodule = base.appendingPathComponent("super/sub")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        // A submodule's git dir has no `commondir`: it is not a worktree of the superproject.
        try "gitdir: ../.git/modules/sub\n".write(to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(RepositoryRoot.of(submodule.path) == canonical(submodule))

        // A worktree of a bare repository belongs to the bare repository.
        let bare = base.appendingPathComponent("project.git")
        let linked = bare.appendingPathComponent("worktrees/feature")
        let checkout = base.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "../..\n".write(to: linked.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(linked.path)\n".write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(RepositoryRoot.of(checkout.path) == canonical(bare))

        let plain = base.appendingPathComponent("plain/deep")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(RepositoryRoot.of(plain.path) == canonical(plain))
    }
}
