import Foundation
import Testing
@testable import SextantCore

/// A symbol the index records only declarations of — a C function declared in a header and
/// defined nowhere the build saw — exists: `who_defines` shows it, and the other tools do not call
/// it unknown.
@Suite("Declared-only symbols (e2e)", .serialized)
struct DeclaredOnlySymbolTests {
    @Test("list_implementations does not call a declared-only symbol unknown",
          .enabled(if: BuildProducts.hasSextantBinary, "sextant is not built — run `swift build` first"),
          .timeLimit(.minutes(5)))
    func declaredOnlySymbolIsKnown() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sextant-declared-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), root = base.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try BuildProducts.writeCPackage(at: root, swift: "import CLib\nlet value = lib_value()\n")
        try "int lib_value(void);\nint lib_declared_only(int input);\n"
            .write(to: root.appendingPathComponent("Sources/CLib/include/lib.h"), atomically: true, encoding: .utf8)
        try "#include \"lib.h\"\nint lib_value(void) { return lib_declared_only(1); }\n"
            .write(to: root.appendingPathComponent("Sources/CLib/lib.c"), atomically: true, encoding: .utf8)
        let index = try BuildProducts.runSextant(["index", "--project", root.path], home: home)
        try #require(index.code == 0, "\(index.errors)")

        let defined = try BuildProducts.callTool("who_defines", ["symbol": "lib_declared_only"], project: root, home: home)
        #expect(defined.text.contains("lib_declared_only"), "\(defined.text)")
        let implementations = try BuildProducts.callTool("list_implementations", ["symbol": "lib_declared_only"],
                                                         project: root, home: home)
        #expect(!implementations.isError, "\(implementations.text)")
        #expect(implementations.text.hasPrefix("no implementations found: lib_declared_only"), "\(implementations.text)")

        let unknown = try BuildProducts.callTool("list_implementations", ["symbol": "no_such_symbol_anywhere"],
                                                 project: root, home: home)
        #expect(unknown.isError && unknown.text == "symbol not found: no_such_symbol_anywhere")
    }
}
