import Foundation
import Testing
@testable import SextantCore

/// `api` must list the public surface completely and `changed` must report every change to it.
/// Each test here states one declaration shape that used to be misread, and what the answer is.
@Suite("Declaration surface (api and changed)")
struct DeclarationSurfaceTests {
    private func declarations(_ source: String) -> [Declaration] {
        SwiftDeclarationExtractor.declarations(source: source)
    }

    private func diff(_ old: String, _ new: String) -> DeclarationDiff.Result {
        DeclarationDiff.compare(old: declarations(old), new: declarations(new))
    }

    private func member(_ name: String, in declarations: [Declaration]) -> Declaration? {
        for declaration in declarations {
            if declaration.name == name { return declaration }
            if let found = member(name, in: declaration.members) { return found }
        }
        return nil
    }

    // MARK: - Setter access

    @Test("A setter modifier does not decide the declaration's access; it stays in the signature")
    func setterAccessIsNotTheDeclarationAccess() throws {
        let source = """
        public struct S {
            public private(set) var a: Int
            private(set) public var b: Int
            public fileprivate(set) var c: Int
            internal(set) public var d: Int
            public package(set) var e: Int
            package var f: Int
            private(set) var g: Int
        }
        open class C {
            open internal(set) var h: Int = 0
        }
        """
        let all = declarations(source)
        for name in ["a", "b", "c", "d", "e", "h"] {
            let property = try #require(member(name, in: all))
            #expect(property.access == .public, "\(name): \(property.header)")
        }
        #expect(try #require(member("f", in: all)).access == .internal)
        #expect(try #require(member("g", in: all)).access == .internal)
        #expect(try #require(member("b", in: all)).header.contains("private(set)"))
        #expect(try #require(member("d", in: all)).header.contains("internal(set)"))

        // Narrowing the setter is a change to the contract even though the getter is untouched.
        let narrowed = diff("public struct S { public var a: Int }", "public struct S { public private(set) var a: Int }")
        #expect(narrowed.changed.count == 1)
    }

    // MARK: - Text rendering of api

    @Test("Text api renders every nesting level and conformance-only extensions")
    func rendersDeepMembersAndConformances() {
        let source = """
        public struct Outer {
            public struct Inner {
                public struct Deep {
                    public func deepest() {}
                }
            }
        }
        extension Outer: Equatable {}
        struct Hidden {}
        extension Hidden: Hashable {}
        """
        let surface = PublicAPI.surface(of: [FileSummary(relativePath: "A.swift", package: "Pkg",
                                                         declarations: declarations(source))])
        let output = PublicAPI.render(surface)
        #expect(output.contains("func deepest()"))
        #expect(output.contains("extension Outer: Equatable"))
        // A conformance of a type the module does not make public is not public surface.
        #expect(!output.contains("Hidden"))
        // The text and `--json` state the same surface.
        let listed = surface.flatMap(\.declarations)
        #expect(listed.contains { $0.header == "extension Outer: Equatable" })
        #expect(output.contains("declarations: 5"))
    }

    // MARK: - Matching declarations that share a name

    @Test("Two extensions of one type are each compared, not collapsed into one key")
    func comparesEachExtensionBlock() {
        let old = """
        extension Foo { public func a() {} }
        extension Foo { public func b() {} }
        """
        let new = """
        extension Foo { public func a() {} }
        extension Foo { public func b(x: Int) {} }
        """
        let result = diff(old, new)
        // Each block is matched to its counterpart, so `b` is one method whose signature changed.
        #expect(result.changed.map { "\($0.old.header) → \($0.new.header)" } == ["Foo.func b() → Foo.func b(x: Int)"])
        #expect(result.added.isEmpty && result.removed.isEmpty)

        // A new block inserted before an existing one attributes nothing to the wrong block.
        let inserted = diff("extension Foo { public func a() {} }",
                            "extension Foo { public func z() {} }\nextension Foo { public func a() {} }")
        #expect(inserted.added.map(\.header) == ["extension Foo"])
        #expect(inserted.removed.isEmpty)
        #expect(inserted.changed.isEmpty)
    }

    @Test("An overload whose signature changed is reported as changed, matched by its labels")
    func matchesOverloadsByLabels() {
        let result = diff("func f(x: Int) {}\nfunc f(x: String) {}\nfunc f(y: Int) {}",
                          "func f(x: Int) -> Bool { true }\nfunc f(x: String) {}\nfunc f(y: Int) {}")
        #expect(result.changed.map(\.new.header) == ["func f(x: Int) -> Bool"])
        #expect(result.added.isEmpty && result.removed.isEmpty)
    }

    // MARK: - What the compared signature holds

    @Test("Every part of the public contract is in the compared signature", arguments: [
        ("@discardableResult public func f() -> Int { 0 }", "public func f() -> Int { 0 }"),
        ("@available(*, deprecated) public func f() {}", "public func f() {}"),
        ("@MainActor public final class A {}", "public final class A {}"),
        ("@objc public protocol P {}", "public protocol P {}"),
        ("@frozen public struct S {}", "public struct S {}"),
        ("public typealias T = Int", "public typealias T = String"),
        ("public protocol P { var x: Int { get } }", "public protocol P { var x: Int { get set } }"),
        ("public struct S { public var x: Int { 1 } }", "public struct S { public var x: Int }"),
        ("public struct S { public subscript(i: Int) -> Int { 1 } }",
         "public struct S { public subscript(i: Int) -> Int { get { 1 } set {} } }"),
        ("public class A {}", "open class A {}"),
        ("public class A { public func f() {} }", "public class A { open func f() {} }"),
        ("public class A {}", "public final class A {}"),
        ("public struct S { public func f() {} }", "public struct S { public mutating func f() {} }"),
        ("public struct S<T> { public init() where T: Equatable {} }",
         "public struct S<T> { public init() where T: Hashable {} }"),
        ("public struct S<T> { public subscript(i: Int) -> T where T: Equatable { fatalError() } }",
         "public struct S<T> { public subscript(i: Int) -> T where T: Hashable { fatalError() } }"),
        ("public protocol P { associatedtype E }", "public protocol P { associatedtype E: Hashable }"),
        ("public protocol P {}", "public protocol P { associatedtype E }"),
        ("public macro m() = #externalMacro(module: \"M\", type: \"T\")",
         "public macro m(_ x: Int) = #externalMacro(module: \"M\", type: \"T\")"),
        ("public enum E: Int { case a = 1 }", "public enum E: Int { case a = 2 }"),
    ])
    func contractPartsAreCompared(old: String, new: String) {
        #expect(!diff(old, new).isEmpty, "\(old)  →  \(new)")
    }

    @Test("What is not contract stays out: bodies, observers, attribute order, deinit", arguments: [
        ("public struct S { public var x: Int { 1 } }", "public struct S { public var x: Int { 2 } }"),
        ("public func f() { a() }", "public func f() { b() }"),
        ("public struct S { public var y: Int = 1 { didSet {} } }",
         "public struct S { public var y: Int = 2 { didSet { print(y) } } }"),
        ("@MainActor @objc public class A {}", "@objc @MainActor public class A {}"),
        ("public class A {}", "public class A { deinit {} }"),
        ("public enum E { case a, b }", "public enum E {\n    case a\n    case b\n}"),
        ("@inline(__always) public func f() {}", "public func f() {}"),
    ])
    func nonContractIsNotAChange(old: String, new: String) {
        #expect(diff(old, new).isEmpty, "\(old)  →  \(new)")
    }

    @Test("Associated types and macros are part of the extracted surface")
    func extractsAssociatedTypesAndMacros() throws {
        let all = declarations("""
        public protocol P { associatedtype Element: Hashable = Int }
        public macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "M", type: "S")
        """)
        let element = try #require(member("Element", in: all))
        #expect(element.header == "associatedtype Element: Hashable = Int")
        #expect(element.access == .public)
        let macro = try #require(all.first { $0.name == "stringify" })
        #expect(macro.header == "macro stringify<T>(_ value: T) -> (T, String)")
    }

    // MARK: - Header changes do not hide member changes

    @Test("A type whose header changed still reports the changes to its members")
    func headerChangeKeepsMemberChanges() {
        let result = diff("public struct A: P { public func f() {} }",
                          "public struct A: Q { public func g() {} }")
        #expect(result.changed.map(\.new.header) == ["struct A: Q"])
        #expect(result.added.map(\.header) == ["A.func g()"])
        #expect(result.removed.map(\.header) == ["A.func f()"])
    }

    // MARK: - Enum cases

    @Test("Cases under #if keep their condition, and re-wrapping a case list is no change")
    func enumCasesKeepConditions() throws {
        let source = """
        public enum E {
            case a
        #if os(iOS)
            case b, c
        #endif
        }
        """
        let all = declarations(source)
        let cases = try #require(all.first).members
        #expect(cases.first { $0.header == "case a" }?.condition == nil)
        #expect(cases.first { $0.header == "case b, c" }?.condition == "#if os(iOS)")

        let rewrapped = """
        public enum E {
            case a
        #if os(iOS)
            case b
            case c
        #endif
        }
        """
        #expect(diff(source, rewrapped).isEmpty)

        let movedOut = """
        public enum E {
            case a, c
        #if os(iOS)
            case b
        #endif
        }
        """
        let result = diff(source, movedOut)
        #expect(result.changed.count == 1)
        #expect(result.changed.first?.old.condition == "#if os(iOS)")
        #expect(result.changed.first?.new.condition == nil)
    }
}

/// The C-family side: declarations clang reports that the walk used to pass over. These parse
/// self-contained text, so they need libclang and no build.
@Suite("C-family declaration surface", .serialized)
struct CFamilyDeclarationSurfaceTests {
    private static var hasClang: Bool { ClangLibrary.discoverPath() != nil }

    private func declarations(_ source: String, fileExtension: String, language: String) throws -> [Declaration] {
        try parse(source, fileExtension: fileExtension, language: language).declarations
    }

    private func parse(_ source: String, fileExtension: String,
                       language: String) throws -> (declarations: [Declaration], unit: ClangTranslationUnit) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-cdecl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Sample.\(fileExtension)")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let unit = try ClangTranslationUnit.parse(file: file.path, arguments: ["-x", language],
                                                  library: try ClangLibrary.shared())
        #expect(unit.isComplete, "\(unit.errors.map(\.text))")
        let declarations = ClangDeclarations.declarations(of: unit.root.children, source: Data(source.utf8),
                                                          publicOnly: false, access: .internal)
        return (declarations, unit)
    }

    @Test("Declarations inside extern \"C\" are read", .enabled(if: hasClang, "libclang is not installed"))
    func readsLinkageSpecifications() throws {
        let found = try declarations("""
        extern "C" {
        int c_entry(void);
        struct Record { int field; };
        }
        """, fileExtension: "cpp", language: "c++")
        #expect(found.map(\.name).contains("c_entry"))
        #expect(found.map(\.name).contains("Record"))
    }

    @Test("An Objective-C class extension is read", .enabled(if: hasClang, "libclang is not installed"))
    func readsClassExtensions() throws {
        let found = try declarations("""
        @interface Foo
        @end
        @interface Foo ()
        - (void)hidden;
        @end
        """, fileExtension: "m", language: "objective-c")
        let extensionDeclaration = try #require(found.first { $0.kind == .extensionKind })
        #expect(extensionDeclaration.header == "@interface Foo ()")
        #expect(extensionDeclaration.members.map(\.header) == ["- (void)hidden"])
    }

    @Test("A multi-line Objective-C header is read whole", .enabled(if: hasClang, "libclang is not installed"))
    func readsMultiLineHeaders() throws {
        let found = try declarations("""
        @protocol P1
        @end
        @protocol P2
        @end
        @interface Base
        @end
        @interface Foo : Base <P1,
                               P2>
        - (void)doA:(int)a
               with:(int)b;
        @end
        """, fileExtension: "m", language: "objective-c")
        let foo = try #require(found.first { $0.name == "Foo" })
        #expect(foo.header == "@interface Foo : Base <P1, P2>")
        #expect(foo.members.map(\.header) == ["- (void)doA:(int)a with:(int)b"])
    }

    @Test("A change under an inactive #if is named, not passed over in silence",
          .enabled(if: hasClang, "libclang is not installed"))
    func namesChangesInSkippedRegions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.c").path
        let before = "int a(void);\n#if 0\nint g(void);\n#endif\n"
        let after = "int a(void);\n#if 0\nint g(int x);\n#endif\n"
        try before.write(toFile: file, atomically: true, encoding: .utf8)
        let library = try ClangLibrary.shared()

        let changed = try CFamilyDiff.compare(old: before, new: after, file: file, arguments: ["-x", "c"],
                                              library: library, from: "HEAD")
        // clang never sees `g`, so the declaration diff is empty — and the answer says why.
        #expect(changed.result.isEmpty)
        let note = try #require(changed.unanalysed)
        #expect(note.contains("lines 2–4"), "\(note)")

        // Untouched inactive code is no reason to qualify the answer.
        let untouched = try CFamilyDiff.compare(old: before, new: "int a(int y);\n#if 0\nint g(void);\n#endif\n",
                                                file: file, arguments: ["-x", "c"], library: library, from: "HEAD")
        #expect(untouched.unanalysed == nil)
        #expect(untouched.result.changed.count == 1)
    }

    @Test("A renamed C file is read at its previous path, so a pure move changes nothing",
          .enabled(if: hasClang, "libclang is not installed"))
    func readsRenamedFilesAtTheirPreviousPath() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("sextant-crename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        let body = (1...12).map { "int keep\($0)(void) { return \($0); }" }.joined(separator: "\n")
        try (body + "\nint moved(void) { return 0; }\n").write(to: repo.appendingPathComponent("old.c"),
                                                              atomically: true, encoding: .utf8)
        try git(["init", "-q"])
        try git(["add", "."])
        try git(["commit", "-q", "-m", "one"])
        try git(["mv", "old.c", "new.c"])
        try (body + "\nint moved(int x) { return x; }\n").write(to: repo.appendingPathComponent("new.c"),
                                                                atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "two"])

        let files = try #require(SwiftSources.changedFiles(root: repo.path, from: "HEAD~1", to: "HEAD"))
        #expect(files.renamedFrom == ["new.c": "old.c"])
        let newFile = repo.appendingPathComponent("new.c").path
        let outcome = CFamilyDiff.changes(
            files: files.clang, topLevel: files.topLevel, projectRoot: repo.path, from: "HEAD~1", to: "HEAD",
            renamedFrom: files.renamedFrom,
            commands: [CompileCommand(directory: repo.path, file: newFile, arguments: ["clang", "-x", "c", "-c", newFile])])
        #expect(outcome.notDiffed.isEmpty, "\(outcome.notDiffed)")
        let change = try #require(outcome.files.first)
        #expect(change.file == "new.c (renamed from old.c)")
        // Only `moved` changed; read at the wrong path, every function would have been "added".
        #expect(change.result.added.isEmpty && change.result.removed.isEmpty)
        #expect(change.result.changed.map(\.new.name) == ["moved"])
    }
}
