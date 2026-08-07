import Foundation
import Testing
@testable import SextantCore

/// The clang layer against real files. A hand-written sample would prove nothing here: what is
/// under test is that the declared ABI matches the libclang on this machine and that the flags
/// captured from the build actually produce a complete tree.
@Suite("Clang translation unit", .serialized)
struct ClangTranslationUnitTests {
    private static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndexFixture")
    }

    private static var isReady: Bool {
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".build").path)
            && ClangLibrary.discoverPath() != nil
    }

    private func commands() -> [CompileCommand] {
        CompilationDatabase.capture(fromStores: IndexStoreLocator.stores(under: Self.fixture))
    }

    @Test("Every C-family source parses without an error, on the flags from the build",
          .enabled(if: isReady, "the fixture is not built and indexed (`make fixture`), or there is no toolchain"))
    func parsesEveryLanguage() throws {
        let library = try ClangLibrary.shared()
        let commands = commands()
        #expect(commands.count >= 3)

        for command in commands {
            let unit = try ClangTranslationUnit.parse(
                file: command.file,
                arguments: CompilationDatabase.parseArguments(of: command),
                library: library
            )
            // A tree with errors is a tree built on the wrong flags; the whole design rests on
            // this not happening.
            #expect(unit.errors.isEmpty, "\(command.file): \(unit.errors.map { $0.text }.joined(separator: "; "))")
            #expect(!unit.root.children.isEmpty, "\(command.file): no declarations")
        }
    }

    @Test("The Objective-C tree carries the shapes a pattern will match",
          .enabled(if: isReady, "the fixture is not built and indexed (`make fixture`), or there is no toolchain"))
    func objectiveCTreeHasMessageExpressions() throws {
        let library = try ClangLibrary.shared()
        let command = try #require(commands().first { $0.file.hasSuffix("ObjCFixture.m") })
        let unit = try ClangTranslationUnit.parse(
            file: command.file,
            arguments: CompilationDatabase.parseArguments(of: command),
            library: library
        )

        var kinds: Set<String> = []
        var spellings: Set<String> = []
        func walk(_ node: ClangNode) {
            kinds.insert(node.kindName)
            spellings.insert(node.spelling)
            node.children.forEach(walk)
        }
        walk(unit.root)

        #expect(kinds.contains("ObjCImplementationDecl"))
        #expect(kinds.contains("ObjCInstanceMethodDecl"))
        #expect(kinds.contains("ObjCMessageExpr"))
        #expect(spellings.contains { $0.hasPrefix("ocGreetWithName") })
        // Declarations from the imported headers belong to those headers, not to this file.
        #expect(!spellings.contains("NSObject"))
    }

    @Test("A node points at real text in the file",
          .enabled(if: isReady, "the fixture is not built and indexed (`make fixture`), or there is no toolchain"))
    func nodeOffsetsSelectTheSource() throws {
        let library = try ClangLibrary.shared()
        let command = try #require(commands().first { $0.file.hasSuffix("ObjCFixture.m") })
        let unit = try ClangTranslationUnit.parse(
            file: command.file,
            arguments: CompilationDatabase.parseArguments(of: command),
            library: library
        )
        let source = try #require(FileManager.default.contents(atPath: command.file))

        var implementation: ClangNode?
        func find(_ node: ClangNode) {
            if node.kindName == "ObjCImplementationDecl" { implementation = node }
            node.children.forEach(find)
        }
        find(unit.root)

        let declaration = try #require(implementation)
        #expect(declaration.line > 0)
        let text = String(decoding: source[declaration.startOffset..<declaration.endOffset], as: UTF8.self)
        #expect(text.hasPrefix("@implementation"))
    }

    @Test("A file with no flags is refused, never parsed with a guess",
          .enabled(if: isReady, "the fixture is not built and indexed (`make fixture`), or there is no toolchain"))
    func refusesWithoutFlags() throws {
        let library = try ClangLibrary.shared()
        let command = try #require(commands().first { $0.file.hasSuffix("ObjCFixture.m") })

        // What "no flags" costs: without the include paths and the SDK, the same file that parses
        // cleanly above does not produce a usable tree.
        let unit = try ClangTranslationUnit.parse(file: command.file, arguments: [], library: library)
        #expect(!unit.isComplete)
    }
}
