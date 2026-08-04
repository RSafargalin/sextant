import Foundation
import Testing
@testable import SextantCore

/// The catalog is the single source of truth about commands and flags: the help, the per-command
/// help, and validation are all built from it. The value-flag list used to be hand-maintained and drifted.
@Suite("Command catalog")
struct CommandCatalogTests {
    @Test("Every command is described: name, summary, group")
    func everyCommandIsDescribed() {
        #expect(!CommandCatalog.commands.isEmpty)
        for spec in CommandCatalog.commands {
            #expect(!spec.name.isEmpty)
            #expect(!spec.summary.isEmpty, "\(spec.name): no summary")
            #expect(!spec.group.isEmpty, "\(spec.name): no group")
            #expect(spec.flags.allSatisfy { $0.name.hasPrefix("--") }, "\(spec.name): a flag without --")
            #expect(spec.flags.allSatisfy { !$0.summary.isEmpty }, "\(spec.name): a flag without a description")
        }
    }

    @Test("Command names are unique and flags are not duplicated within a command")
    func namesAreUnique() {
        let names = CommandCatalog.commands.map(\.name)
        #expect(Set(names).count == names.count)
        for spec in CommandCatalog.commands {
            let flags = spec.flags.map(\.name)
            #expect(Set(flags).count == flags.count, "\(spec.name): duplicated flag")
        }
    }

    @Test("The same flag has the same nature everywhere (value or switch)")
    func flagKindsAreConsistent() {
        var kinds: [String: Bool] = [:]
        for spec in CommandCatalog.commands {
            for flag in spec.flags {
                if let known = kinds[flag.name] {
                    #expect(known == flag.takesValue, "\(flag.name): different nature in \(spec.name)")
                }
                kinds[flag.name] = flag.takesValue
            }
        }
    }

    @Test("valueFlags is derived from the catalog rather than maintained by hand")
    func valueFlagsDerived() {
        let flags = CommandCatalog.valueFlags
        for expected in ["--project", "--budget", "--scope", "--limit", "--from", "--to", "--type", "--package"] {
            #expect(flags.contains(expected), "\(expected) is missing from valueFlags")
        }
        // Switches must not swallow the next token.
        for switchFlag in ["--json", "--full", "--verify", "--app", "--force"] {
            #expect(!flags.contains(switchFlag), "\(switchFlag) is wrongly declared as value-taking")
        }
    }

    @Test("An unknown flag is caught; --help is allowed everywhere")
    func unknownFlagsDetected() throws {
        let map = try #require(CommandCatalog.command(named: "map"))
        #expect(CommandCatalog.unknownFlags(in: ["--budget", "500", "--json"], for: map).isEmpty)
        #expect(CommandCatalog.unknownFlags(in: ["--help"], for: map).isEmpty)
        #expect(CommandCatalog.unknownFlags(in: ["--budjet", "500"], for: map) == ["--budjet"])
    }

    @Test("A typo suggests the nearest flag; something unrelated does not")
    func suggestsClosestFlag() throws {
        let map = try #require(CommandCatalog.command(named: "map"))
        #expect(CommandCatalog.closestFlag(to: "--budjet", in: map) == "--budget")
        #expect(CommandCatalog.closestFlag(to: "--jsn", in: map) == "--json")
        #expect(CommandCatalog.closestFlag(to: "--wat", in: map) == nil)
    }

    @Test("Per-command help contains the invocation, the flags, and the notes")
    func perCommandHelp() throws {
        let refs = try #require(CommandCatalog.command(named: "refs"))
        let help = CommandCatalog.help(for: refs)
        #expect(help.contains("sextant refs <symbol>"))
        #expect(help.contains("--project <val>"))
        #expect(help.contains("--verify"))
    }

    @Test("The general help lists every command, grouped")
    func overviewListsEverything() {
        let overview = CommandCatalog.overview()
        for spec in CommandCatalog.commands {
            #expect(overview.contains(spec.name), "\(spec.name) is missing from the general help")
        }
        #expect(overview.contains("Semantics (index store):"))
    }

    @Test("The catalog covers every dispatched command, or flags go unvalidated")
    func catalogCoversDispatch() throws {
        // Names are taken from dispatch itself: the only way to catch a command added outside the
        // catalog, which would silently have neither --help nor flag checking.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/SextantCoreTests/CommandCatalogTests.swift",
            with: "Sources/sextant/main.swift"), encoding: .utf8)
        let dispatched = source.split(separator: "\n")
            .filter { $0.contains("case \"") && $0.contains("return run") }
            .flatMap { line -> [String] in
                line.split(separator: "\"").enumerated().compactMap { $0.offset % 2 == 1 ? String($0.element) : nil }
            }
            .filter { !$0.hasPrefix("-") }

        #expect(!dispatched.isEmpty, "could not parse dispatch — the test would stop checking anything")
        for command in dispatched {
            #expect(CommandCatalog.command(named: command) != nil, "command '\(command)' is in dispatch but not in the catalog")
        }
    }

    @Test("Levenshtein distance: basic cases")
    func editDistance() {
        #expect(CommandCatalog.editDistance("", "") == 0)
        #expect(CommandCatalog.editDistance("--json", "--json") == 0)
        #expect(CommandCatalog.editDistance("--budget", "--budjet") == 1)   // one substitution g→j
        #expect(CommandCatalog.editDistance("--budget", "--budgets") == 1)  // one insertion
        #expect(CommandCatalog.editDistance("", "abc") == 3)
    }
}
