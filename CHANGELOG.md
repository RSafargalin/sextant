# Changelog

**English** | [Русский](CHANGELOG.ru.md)

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The stability contract covers **CLI flags, JSON output schemas, MCP tool names and their
input schemas, and exit codes**. Breaking any of those requires a major version bump.
Human-readable text output is not covered — parse `--json`, not prose.

## [Unreleased]

### Added

- **A Claude Code plugin, distributed from this repository.** `/plugin marketplace add
  RSafargalin/sextant` then `/plugin install sextant@sextant` registers the MCP server for every
  project opened, a skill that says when to ask the index instead of grepping, and a
  `/sextant:setup` command that runs `doctor` and offers to build an index. The wiring drops from
  four manual steps to one; the binary is still Homebrew's job, and the launcher says so by name
  instead of failing silently. It registers no hooks: the adoption hook writes from the moment it
  is installed, which keeps it a decision for `hook --install` rather than a side effect of an
  install.
- **`body --context-lines N`** — N lines on each side of the declaration, numbered, with the
  declaration itself marked apart from its surroundings. Measured on another tool of the same shape:
  18.4 % of symbol queries were followed by a plain read of the same file, and in four fifths of
  those the body had already been delivered — the agent held the declaration and was reaching for
  what sits around it.
- **A follow-up count in `sextant adoption`** — how many of our answers were followed *next* by
  opening a file. A share says how often the tool was reached for; this says whether the answer was
  enough. It measures adjacency, not the same file, and says so.
- **`sextant doctor` checks the wiring, not only itself** — the MCP registration and the adoption
  hook: whether the binary each names exists, and whether the hook has ever recorded anything. Every
  check before this was about the tool's own process, which is how a hook that was registered
  nowhere passed a green check-up for ten days.

### Fixed

- **`ugrep` and `bfs` are counted as the searches they are.** A client that routes `Grep` and `Glob`
  through the shell as those binaries was invisible to the adoption denominator. One list now serves
  both the hook and the transcript reader, and the test walks the whole list.
- **A store with units but no records is named, not blamed on the symbol.** Such a store resolves
  nothing while dating itself as fresh, and the answer explained it as "does not resolve semantically
  (a closure, a local, or another kind of symbol)" — a confident diagnosis of the wrong thing.
- **A daemon stopped by SIGINT or SIGTERM removes its socket.** Ownership was already held by an
  flock, so an orphan blocked nothing, but a socket file outliving its process claims a listener that
  is not there.
- **The MCP handshake answers with the revision this build implements**, instead of echoing whatever
  the client asked for — which turned every client's guess, including revisions published after the
  binary was compiled, into confirmation.

## [0.9.0] — 2026-08-17

An answer now says what it stands on. Which index store it came from and how much of the project
that store covers; whether a number is the whole count or the part that fit; where a symbol is
defined as opposed to where it is called. The work started as one bug — the wrong store was chosen
on a project with agent worktrees, so every semantic answer was empty under a `fresh` label — and
turned into a pass over every place the tool answered confidently without being able to. Forty
defects were reproduced by running the tool, written down as tests that fail when they are fixed,
and closed. Six public repositories and the reference project were used to check that they stay
closed.

### Added

- **`sextant store` and an explicit store policy.** A project routinely has more than one index
  store — `swift build` writes one, an editor's indexer another, a second checkout its own — and
  they answer the same question differently: measured on this repository, 83 references from one
  and 34 from another, 91 from both merged. So the tool no longer chooses. With one usable store
  nothing is asked; with several and no policy, semantic commands refuse and print what each policy
  gives, what it does not and what it costs. `store use recency|union|coverage` records the choice
  in `.sextant.json`; `--store-policy` overrides it for one command, `SEXTANT_STORE_POLICY` for one
  machine. Whenever there was a choice, every answer carries the line that says how many candidates
  there were, which are being read and why the others were not
  ([ADR-0006](docs/adr/0006-store-policy-is-a-persons-decision.md)).

- **Coverage of the opened store, in the trust label.** `[index: derivedData · 1 store(s) · fresh ·
  covers 10337/12351 files (84%)]`. Freshness is about time, coverage is about extent, and a fresh
  store can hold half a project: a release build compiles no test target, so every reference from a
  test is missing from a store nothing else marked as partial. Measured on this repository, the same
  query against two stores of one project: `covers 92%` → 74 usages in 23 files, `covers 55%` → 46
  in 17. It is read from the units, cached against the store's own state, and costs nothing on every
  run but the first after a build.

- **A units reader for libIndexStore** (`CIndexStoreShim`, `dlopen` over a declared subset of the
  ABI, as the libclang layer already does). IndexStoreDB answers about symbols and cannot tell "this
  store does not cover the file" from "the file has no such symbol"; a unit answers directly — this
  is the file it was built from. It is what makes the `coverage` policy and the label above possible.

- **`api --budget <tokens>`** bounds the printed surface and the header then states what was left
  out. There is no default: a public surface is a contract, and cutting one silently changes what
  every existing answer says. Over MCP the budget does have a default — an agent reads the answer
  into a context window.

- **`--derived-data` and `SEXTANT_DERIVED_DATA`.** The DerivedData location was hard-coded, so a
  project built with `xcodebuild -derivedDataPath ./build` — which every CI does — looked like a
  project with no index at all.

- `index` now states what it runs and what holds it back, and it says something different for each
  path, because the two are not equally protected. Measured with a hostile manifest and a hostile
  build plugin: SwiftPM sandboxes both — no network, no writes into your home directory — but they
  can read it; `--app` runs `Run Script` phases with your full access and no sandbox at all. Both
  notices name `--no-build`, which indexes an already-built project and runs nothing. Three MCP
  tool descriptions sent an agent to run `sextant index` without ever saying it builds the project;
  they say it now. Wrapping the build in `sandbox-exec` was measured and is impossible — SwiftPM
  applies its own sandbox and a nested one is denied by the kernel.

- `init --client <name>` registers the MCP server for a client other than Claude Code. The list is
  `claude-code` (default, a file in the project) and `claude-desktop` (one list per machine, so the
  project is named in the arguments). Everything the `.mcp.json` path was already careful about now
  holds for every client: other servers in the file survive, a file that does not parse or whose
  servers key is not an object is left alone rather than repaired, already-registered is reported
  rather than treated as an error, and the entry carries the absolute path to the running binary.
  The client name is validated before anything is written, so a typo does not leave half a setup
  behind. Closes [#7](https://github.com/RSafargalin/sextant/issues/7).

- `exclude` in `.sextant.json` and a repeatable `--exclude` flag: globs for files that are tracked
  on purpose and still have no business in an answer — generated code, vendored sources, snapshot
  fixtures. `--scope` could only narrow to one subtree; it cannot subtract. The filter sits after
  both discovery paths, so a git project and a non-git one leave out exactly the same files, and
  the syntax is a small predictable part of glob (`*`, `**`, a bare name at any depth) rather than
  a subset of gitignore — a partial gitignore is unpredictable, and unpredictable exclusions hide
  code without the user knowing. Closes [#9](https://github.com/RSafargalin/sextant/issues/9).

- [docs/recipes.md](docs/recipes.md) — twelve questions and the commands that answer them, with
  real output: is this type safe to delete, who calls this through the protocol, what changed on
  this branch symbol by symbol. Everything shown was produced by running the command against
  Alamofire at `0455bfb`, which the page names so a reader can reproduce it, and re-running them
  is now a step in the release checklist — documentation that drifts silently is worse than none.
  Closes [#6](https://github.com/RSafargalin/sextant/issues/6).

- `completion zsh` and `completion bash` print a completion script, generated from the command
  catalog — the same data that builds the help and validates flags, so a command added later
  cannot silently fall out of completion. Flags are offered per command rather than as one flat
  list, a flag that takes a value expects one instead of suggesting the next flag, and `--project`,
  `--scope` and `--index-store` complete directories while `--rules` and `--spec` complete files.
  Closes [#2](https://github.com/RSafargalin/sextant/issues/2).

### Fixed

- **The wrong index store was chosen on a project with nested worktrees, and every semantic answer
  was empty.** An agent worktree lives inside the checkout, so its DerivedData passed the "inside
  the project" test, and being rebuilt more recently it also won on freshness — after which the
  record filter rejected every path in it as foreign. On the reference project `refs
  AbsAccountsViewModel` returned nothing and explained it as "a closure, a local, or another kind of
  symbol" about a class; it now returns the definition and 7 usages in 3 files. Selection applies the
  same scope predicate the filter applies; where a foreign store is used anyway, the empty answer
  names it instead of inventing a reason.

- **A call hierarchy pointed at call sites and called them definitions.** `timestamp(ofStore:)` was
  shown at line 48 — where it is called — while it is defined at line 25, and nothing said which of
  the two it meant. The definition is now resolved by USR, the call site is a separate field, and a
  symbol the index has no definition for is marked rather than given a made-up position.

- **A reference written inside a macro was counted twice.** A macro records the reference at its own
  position as well as at the real column, so every count over code wrapped in `#expect`/`#require`
  came out high: 81 against 74 occurrences of the name on this repository. A position whose column
  does not carry the symbol's name is dropped when another position on the same line does; a lone
  unverified position is kept, because the name may be written in a form the check cannot see.

- **`api --json` served internal members of public types.** The visibility filter was applied to the
  top level only, so the text answer dropped them and the machine contract carried them — one
  question, two answers. Found on Alamofire.

- **Counts stopped presenting a part as the whole.** `construct` counted one position twice when a
  line held two constructions; `--limit` rewrote the header count instead of shortening the list;
  the internal cap of 1000 references was printed as the total and is now named (`1000 of 1265`).

- **Structural search and lint.** A pattern the parser only recovered from (an unbalanced bracket)
  answered `No matches.` with exit 0 and now fails with the reason — while a pattern that is not
  Swift but is valid Objective-C still goes to clang. `search --limit` was accepted and ignored.
  An exclusion that removed every result is now named. A `lint` rule whose pattern never compiled
  was counted in the header as if it had run.

- **`changed`** now sees a symbol leaving the public surface (the access level is part of the
  compared signature), follows a renamed file instead of reporting a rewrite, and refuses to diff a
  file that does not parse — a recovery tree reported the half it dropped as deleted symbols, which
  is exactly the state an agent's half-finished edit leaves behind.

- **Freshness and staleness.** The freshness signal walked `*.swift` only, so an edit to a `.m` or a
  header left the label saying `fresh`. An answer that points at a deleted file now says so — a
  deletion moves no timestamp, so the marker cannot see it. A snippet is withheld when the recorded
  line no longer carries the symbol, instead of printing whatever text now sits there.

- **Compile flags had no notion of time.** They are captured by `sextant index`; every other build
  moves the index forward and leaves them behind, and a `-DFEATURE=1` that has since become `0`
  yields a structural match inside code the current build does not contain. A build newer than the
  capture is now named, with the gap. Entries for files that no longer exist are dropped when the
  database is read — measured on this machine, two databases held 75 of 75 and 72 of 73 such entries.

- **`--verify` was silent in the two directions that matter.** More semantic hits than textual ones
  cannot be true of a name written where it is used, and it printed the pair without comment. Fewer
  semantic than textual, with the difference sitting inside `#if` branches this build does not
  contain, fell exactly on the wrong side of a ×3 threshold (the measured case was 1 against 3);
  those lines are now counted and named.

- **`--project` pointed at a directory containing several projects borrowed a foreign index.** A path
  prefix is not a project boundary: `--project ~` offered the store of an unrelated app from
  `Downloads`, covering 6% of what it called "this project". The boundary is the checkout.

- **The MCP surface.** Answers carry the provenance line the CLI prints — a client logs stderr at
  best, so the agent, the main consumer, never saw where an answer came from. `repo_map` gets the
  index the CLI gets and names the non-Swift files missing without it. `list_implementations`
  distinguishes an unknown symbol from one without implementations. Area tools are bounded by
  `maxFiles` and say what they did not read. The store policy refusal reaches the answer instead of
  the log. A `.sextant.json` edited while the server runs takes effect on the next call.

- **Smaller refusals that used to pass silently:** an empty symbol, a single-dash flag spelling
  (`-project`), a `--project` that does not exist, an unmatched `api --package`, a misspelled key or
  policy value in `.sextant.json`. The daemon re-reads the file list per request instead of freezing
  it for its lifetime. A package is addressed by the name in its manifest rather than by the first
  path component, so a project that keeps packages outside `Packages/` can address them at all.

- **The daemon's output capture could hang, and did hang CI.** Draining ran as a block on the
  global queue while the caller was already blocked on the write, so anything holding the pool's
  threads — several `Process.waitUntilExit` calls, say — starved the reader that would have
  unblocked it. Reproduced with 80 blocked tasks: the write never returned, and a watchdog on the
  same queue never fired either. Each reader now gets a thread of its own. The test written for the
  original defect passed locally in 0.002s and timed out at 60 seconds on the runner, twice; the
  starvation itself is now a test.

- **The clang layer counted a file nobody could open as scanned**, and a byte that is not valid
  UTF-8 shifted every offset after it, so a column and a snippet were both wrong while presented as
  structural.

### Changed

These are the stability contract — CLI flags, JSON schemas, MCP tool names, exit codes — and this
release breaks some of it, which is why the minor version moves.

- **Exit codes.** Cases that used to answer 0 now fail: an unparsable structural pattern, an empty
  symbol, a single-dash flag, a `--project` that does not exist, an `api --package` that matches
  nothing. Semantic commands exit non-zero when several index stores are usable and no policy is
  set.

- **`--max-files` degrades instead of refusing.** `map`, `api`, `search` and `lint` used to answer
  "more files than the limit" and nothing else; they now read the limit and name what they did not
  (`⚠ covered 4000 of 12351 file(s)`), which changes their exit code on a large project from 1 to 0.
  The bound is a prefix of the file list in a fixed order, so two runs cover the same files.

- **`--json` shapes.** `refs`/`defs`/`callers` return an object rather than an empty array when the
  semantic answer is empty and the textual degradation applies, so a consumer cannot read textual
  matches as resolved ones. `blast`, `hierarchy` and `context` return `{"symbol": …, "found": false}`
  for an unknown symbol where they used to print prose on stdout. `lint --json` carries
  `brokenRules`; `map`/`api` summaries carry the package name from the manifest.

- **Interface Builder is documented as out of scope.** `.storyboard` and `.xib` are not read and not
  planned; a class named only from a nib is invisible. Measured on the reference project: 376 classes
  are bound from nibs and none of them lives only there, so the cost is an undercount in impact
  analysis rather than a false "nobody uses this"
  ([ADR-0007](docs/adr/0007-no-interface-builder.md)).

- **Benchmarks re-measured** for scenarios A and B at the same pinned commits. Every surface is
  larger than at 0.7.0 (Alamofire 973 → 1 226 declarations) because declarations behind `#if` and
  internal extensions carrying public members are now part of the surface; the saving band moves
  from 79–91% to 79–90%.

- A shared IndexStoreDB directory between processes was recorded as a defect and is not one:
  measured, per-process databases are worse at every level of concurrency (4 processes: 34.4s shared
  against 73.8s separate), answers never diverged, and nothing indicated a re-import or corruption.
  The stand is in [docs/measurements](docs/measurements).

## [0.8.1] — 2026-08-07

### Added

- `doctor` reports when `PATH` holds more than one `sextant`, naming which one a shell would run
  and which one is speaking. The two documented install routes land in different directories, and
  a copy from `make install` in `~/.local/bin` usually comes first — so `brew upgrade` succeeds
  while the tool keeps answering with the old version, and nothing points at why.

## [0.8.0] — 2026-08-07

The C family stops being a blind spot. `search`, `lint`, `changed`, `api` and `construct` now
read Objective-C, C and C++ as well as Swift — through clang, with the exact flags each file was
built with, captured from the build. Where an answer cannot cover something, it says so: files
without flags, patterns that do not compile there, and code inside `#if` branches the build does
not contain are all named rather than passed over. `adoption` measures how much of an agent's
code navigation goes through the tool at all.

### Added

- `adoption` — the share of code navigation that went through sextant instead of past it, and,
  more usefully, what went past: the searches an agent ran as text, grouped by the shape of the
  query. An identifier searched with grep is a question `defs` or `refs` answers exactly, so each
  one is either a gap in the tool or a gap in how it describes itself. The share alone would be a
  scoreboard; the residue is what there is to fix.

  The denominator cannot come from sextant — the searches that went elsewhere are invisible to
  it — so it is read from the client's own session transcripts. Only two fields of a record are
  ever looked at, the tool's name and its query, and the query is reduced to a shape immediately:
  no pattern, path or message text is kept or printed unless `--show-queries` asks for it, and
  nothing is sent anywhere.
- `hook` — the same signal live, for a client's `PreToolUse` hook: one line per navigation act
  carrying a timestamp, a hash of the project root, the act and the shape of the query. Not the
  query, not the command, not the path. `sextant hook --install` prints how to install it and
  exactly what it writes; it is off until someone does. Beyond measurement it is the point where a
  later version can offer the answer instead of counting the grep.

- `changed` diffs Objective-C, C and C++ at the symbol level, not just Swift. A past revision has
  no build of its own, but it does not need one: its text is parsed against the flags the file is
  compiled with today, which measures clean. A file with no flags at all, or a revision that does
  not parse, is named with the reason instead of being counted as unchanged.
- `lint` runs its rules over Objective-C, C and C++ as well, reading each file once for all of
  them. A rule written for another language simply does not compile there, which is not a gap; a
  file where **no** rule could run is reported, because nothing about it was checked.
- `api` reports the public surface of C++ headers. They used to come from the index, which lists a
  header's free functions and drops every class — a surface that looks complete and is not,
  because the index carries no access level. A header with any C++ in it is now read through
  clang, private and protected members excluded, using the flags of a translation unit that
  includes it; a header no compiled source includes is named rather than shown as empty. The MCP
  `api` tool answers the same as the CLI, which it did not before: it was never given the index,
  so through MCP the surface was Swift-only.
- `search` reads Objective-C, C and C++ through clang, so a structural pattern is no longer a
  Swift-only question: `sextant search '[$X reloadData]'` finds message sends the way
  `try? $X.save()` finds Swift calls. The pattern is compiled inside each file, appended to it in
  memory, because that is the only place its selectors are known — compiled on its own, an
  Objective-C pattern comes back from clang with an empty selector under ARC. Whatever cannot be
  read is named with its reason (no flags, the pattern does not compile here, a header is not a
  compilation unit), never counted as "no matches".
- Occurrences inside `#if` branches the build does not contain are reported too, as a separate,
  textual tier. clang runs the preprocessor, so such code never reaches the tree and cannot be
  matched structurally — on SDWebImage a search finds 15 usages where grep counts 28, the other
  13 sitting under `#if SD_UIKIT` on a macOS build. Reporting only 15 would leave an agent about
  to change that API to break another platform; merging them would pass a textual guess off as a
  verified match. So both are given, labelled and separate: `15 matches` plus `⚠ 13 more textual
  occurrence(s) inside #if branches not built for x86_64-apple-macosx10.13 — found by text, NOT
  structurally verified`. `--json` carries them in `inactiveOccurrences`. `lint` does the same,
  reporting a rule that matches textually there as a possible violation.

  Swift is not affected and stays broader than the build: SwiftSyntax does not evaluate `#if`, so
  a Swift search covers every branch, including `#if false`. The asymmetry is deliberate — clang
  cannot build a tree without running the preprocessor, and an extra hit sits in plain sight next
  to its `#if` while a silent omission does not.
- A compile database: `index` records the exact flags each Objective-C, C and C++ file was built
  with, and `doctor` reports whether every such source is covered. This is the groundwork for
  reading those files structurally ([ADR-0004](docs/adr/0004-structural-layer-for-c-family.md)):
  clang builds a complete AST only with per-file flags, and roughly a third of one with guessed
  flags — so the flags have to come from the build, and a file without them will be refused rather
  than answered for. They are read from the build graph SwiftPM writes (`.build/<configuration>.yaml`),
  where each clang node carries its arguments as a JSON array, rather than scraped from build
  output: an incremental build that compiles nothing prints nothing, while the graph still
  describes every file. Xcode writes no such graph — its own manifest lists compile nodes without
  their arguments — so there the flags are read from the build log, where the full clang
  invocation is printed, shell-escaped and behind a response file. Because an incremental build
  compiles nothing and therefore prints nothing, a capture merges into what was already known
  rather than replacing it: a project built one scheme at a time would otherwise keep losing the
  flags of everything else.
- Objective-C, C and C++ across the semantic commands. The index store is written by the whole
  clang family, so this needed symbol resolution to be fixed rather than a parser to be added:
  selectors (`greetWithName:`) are now matched, and a symbol declared in a header now resolves
  to its definition in the implementation file.
- `map` and `api` cover the same languages, reading Objective-C and C declarations from the
  index; C++ headers go through clang instead (see above), because the index carries no access
  level.
- `body` extracts C, C++ and Objective-C declarations. It previously answered for Swift only,
  and a C++ struct that happened to parse as Swift came back missing its trailing `;`.
- A four-language fixture (Swift, Objective-C, C, C++) with an Objective-C protocol and its
  conformers, and brace traps inside strings, character literals and comments.
- [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md): the structural layer for the
  C family will be built on libclang, not tree-sitter, with the measurements behind that.
- `golden` accepts `callees` assertions. The command shipped without regression cover in the
  spec that exists to provide it.
- Fixture cover for C++ overloads, an uninstantiated template, a nested namespace and an
  Objective-C category. All four already worked; overloads resolve to separate USRs, so callers
  of one signature are not attributed to the other.

### Changed

- The rule sets no longer drift. `--rules` **replaces** the built-in set, as it always did, and now
  says so in the output; a file may instead be an object with `"extends": "builtin"` to add to
  them, which is the answer to "the defaults plus two of mine" that previously meant copying the
  defaults by hand and losing them at the next release. Every `lint` answer states which set it
  used, because "no violations" from two rules is not the claim it is from five.
- The built-in set is documented as **a starting point, not a safe default for every project** —
  there is no universal set: `print-call` is wrong for a command-line tool and `force-unwrap` is
  noise in interop-heavy code. sextant's own `sextant-rules.json` takes two of them and leaves the
  rest deliberately, which is why its CI never applied `print-call` and nothing said so.
  Closes [#5](https://github.com/RSafargalin/sextant/issues/5).

- **Breaking (`--json` schema):** `search --json` returns `{"matches": [...], "notScanned": [...]}`
  and `lint --json` returns `{"violations": [...], "notScanned": [...]}`, each in place of a bare
  array. Every `notScanned` entry is `{"file": ..., "reason": ...}` — a file left out, and why.
- `search` and `lint` name the non-Swift files they skipped, in the text output, in `--json` and
  in the MCP answer. Both commands walk `.swift` only, so on a project with Objective-C sources
  they used to report "No matches." and "✅ No violations found" about files they had not read —
  a clean bill of health covering unexamined code. The tool descriptions say so too, because an
  agent never sees stderr. Actually reading those files is [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md) work.
- **Breaking (`--json` schema):** `changed --json` returns an object
  `{"files": [...], "notDiffed": [...]}` instead of a bare array; the former array is now the
  `files` field. Each `notDiffed` entry is `{"file": ..., "reason": ...}`.
- `changed` names the C, C++ and Objective-C files it could not compare. It used to drop them, so
  a commit touching only `.m` files reported "no symbol-level changes" — a confident wrong
  answer of exactly the kind this tool exists to prevent.

### Fixed

- `.gitignore` is now honoured in full for a project that is **not** under git. The fallback read
  only bare directory names from it, dropping every line with a `/` or a `*` — so `Generated/**`,
  `[Dd]ebug/` and `Sources/*/Legacy` did nothing, and those files landed in `map`, `api`, `search`
  and `lint`. Rather than growing a subset of gitignore — attempted in
  [#8](https://github.com/RSafargalin/sextant/pull/8), and unpredictable, because a partial
  implementation fails silently — git itself is borrowed: the project becomes a work tree whose
  git dir lives in the cache, so negation, bracket classes, nested `.gitignore` files and
  "last matching pattern wins" all behave exactly as git defines them, and nothing is written
  inside the project. Closes [#3](https://github.com/RSafargalin/sextant/issues/3).

- Conditional compilation no longer makes declarations vanish quietly. `api` and `map` dropped
  everything inside a `#if` — an iOS-only public method was simply absent from the surface on a
  Mac, with nothing said about it. Those declarations are now listed with the condition that
  guards them (`func onlyOnPhone()  [#if os(iOS)]`), and `changed` treats moving a declaration
  under a condition as the API change it is. The declaration cache version was bumped, since its
  key is the file's content and the extraction itself changed.
- A symbol that resolves to nothing now says why when the reason is knowable. "Does not resolve
  semantically (a closure, a local, or another kind of symbol)" was misleading for a symbol that
  exists only inside a `#if` branch this build does not contain — the answer now says exactly
  that, and marks which occurrences are conditional.
- The textual fallback searches Objective-C, C and C++ as well. It walked `.swift` files only, so
  an unresolved Objective-C symbol degraded to a search that never opened a `.m` file and
  reported nothing at all.
- `api` and `map` state when non-Swift files use `#if`: their declarations come from the index,
  which holds one configuration, so a branch that configuration does not contain is not in the
  answer. Swift declarations under `#if` are listed with their condition instead of counted.

- `construct` looked for the Swift shape `Type(` in every language, so on an Objective-C project
  it found nothing at all — which reads as "nothing constructs this type" rather than "this
  command cannot see it". Objective-C creates objects by sending `alloc` or `new` to the class,
  and that is what is looked for there now. A substring match also counted `makeStore(` as
  constructing `Store`; a shape now has to start at a word boundary.
- Index store selection used the store directory's own modification date, which does not change
  when units are rewritten inside it. A stale store could win over a fresh one and the semantic
  commands would answer from it — silently, and wrongly. All three selection sites now use the
  same freshness layer.
- `map` printed two messages about one missing index.
- `callees` counted call sites as callees: a method called twice on one line was reported as two.
  Results are now grouped per symbol, with the extra sites listed under it. `hierarchy` showed the
  same child twice for the same reason, and the duplicate also consumed its breadth budget.

## [0.7.0] — 2026-08-05

First public release.

### Added

- Repository documentation for public use: `README`, `CONTRIBUTING`, `SECURITY`,
  `CODE_OF_CONDUCT`, `AGENTS.md`, issue and pull request templates. Documents written for
  people ship in English and Russian (`*.ru.md`).
- `docs/benchmarks.md` — reproducible measurements on five public Swift packages at pinned
  commits, with the commands to re-run them.
- A regression test for index store selection across build configurations.

### Changed

- Renamed the project from its working title to **sextant**. This touches everything a user
  sees: the binary, the config file (`.sextant.json`), the rules file, the MCP server name,
  the URL scheme, the cache directory (`~/Library/Caches/sextant`) and the
  `SEXTANT_NO_DAEMON` environment variable. There is no migration path from the old names —
  the tool had no public release under them.
- CLI help, MCP tool descriptions, error messages and code comments are now in English.
- `sextant help` shows the build timestamp next to the version, so two builds of the same
  version are distinguishable in the field. `sextant --version` still prints the bare version
  string — it is machine-readable and checked by the release workflow.
- CI and the release workflow run on the `macos-26` runner and select the newest available
  Xcode, failing loudly if the toolchain is older than Swift 6.2.

### Fixed

- **`body` works across the C family.** It parsed every file with SwiftParser, which silently
  mis-handled anything that was not Swift: an Objective-C `@implementation` returned nothing at
  all, so did a C function, and a C++ struct happened to parse as Swift and came back missing its
  trailing `;`. Non-Swift declarations are now delimited instead of parsed — the index already
  gives the exact definition line, so only the end has to be found. Objective-C containers run to
  `@end`, prototypes stop at their semicolon, and braces inside strings, character literals and
  comments are skipped rather than counted.
- **`api` reports the public surface of Objective-C and C targets.** In SwiftPM a target's
  public headers live in `include/`, which is the module map's own answer to what the target
  exposes — so this is the layout's definition of public, not a guess. C++ headers are
  deliberately refused: they declare private members alongside public ones and the index carries
  no access level, so listing them would present private members as public API. `api` says how
  many it left out rather than returning a surface that looks complete.
- **`map` covers Objective-C, C and C++.** Non-Swift files are read from the compiler index
  rather than through a second parser, so the repository map shows the whole project instead of
  its Swift half. A declaration repeated in a header and its implementation is listed once;
  one that exists only in a header is kept, since that is the only place it appears. When such
  files exist but no index has been built, the map says how many it could not read instead of
  quietly omitting them. Swift is still parsed with SwiftSyntax — the index carries no
  visibility information, and the map filters on access level — so a pure-Swift project takes
  exactly the path it did before, with no index required.
- **Semantic commands now resolve Objective-C symbols.** The index store is written by the
  whole clang family, not just swiftc, so Objective-C, C and C++ declarations were always in
  it — but two defects kept them out of reach. Objective-C methods that take arguments are
  stored as selectors (`greetWithName:`), which matched neither an exact name nor Swift's
  `name(` shape, so a bare method name resolved to nothing. And a symbol whose canonical
  occurrence is a header declaration — the norm in Objective-C and C — reported no definition
  at all, because the definition in the `.m` or `.c` was only ever collected as a reference.
  Both are fixed, so `refs`, `defs`, `callers`, `context` and the rest work across a language
  boundary: a Swift call spelled `greet(withName:)` is found as a caller of the Objective-C
  selector it actually calls. C and C++ needed no change; they already worked.

- **Semantic queries went blind on projects that had ever been built in release
  configuration.** The index store was selected by the modification time of the store
  *directory*, but a build rewrites unit files *inside* the store without touching that
  directory. A one-off `swift build -c release` therefore left a small, stale release store
  looking permanently "newer" than the debug store that regular builds keep current. On a
  real project this meant a 110-unit store was chosen over a 2203-unit one: `defs` found only
  test-target symbols, `impls` returned nothing for a protocol with a conforming actor in the
  same file, and every query was labelled `⚠ STALE` immediately after a successful `index`.
  Store selection now uses the same units-based freshness signal as the rest of the tool, in
  all three places that select a store (SPM packages, umbrella build, Xcode DerivedData). A
  store with no units is no longer a candidate at all.
- **`sextant init` wrote a non-existent binary path into `.mcp.json`.** When sextant was
  launched through `PATH`, `argv[0]` is the bare name `sextant`, which was resolved relative
  to the current directory — producing `<project>/sextant`. The launch path now comes from
  the kernel, so the registration points at the real binary. The stable `bin/` symlink is
  still preserved rather than resolved, so `brew upgrade` does not break the registration.

## Earlier versions

Developed privately up to 0.6.x; see `docs/roadmap.md` for the iteration history and the
gates each one had to pass. Those versions were never published, so no compatibility is
claimed for them.
