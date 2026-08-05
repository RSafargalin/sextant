import ObjCFixture

public protocol Greeter {
    func greet() -> String
}

public struct EnglishGreeter: Greeter {
    public init() {}
    public func greet() -> String { helper() }
}

public struct FrenchGreeter: Greeter {
    public init() {}
    public func greet() -> String { "bonjour" }
}

func helper() -> String { "hi" }

// A computed property rather than a global `let`: a global of non-Sendable type is a
// concurrency error under Swift 6. The reference to EnglishGreeter is what the golden set
// asserts on, and it survives.
public var defaultGreeter: Greeter { EnglishGreeter() }

/// Call sites: through the protocol (dynamic dispatch onto the requirement) and through the
/// concrete types (static dispatch onto the implementations) — material for the bare-name spike.
public func runGreeters() -> String {
    let viaProtocol: Greeter = defaultGreeter
    let throughRequirement = viaProtocol.greet()      // dispatch onto the requirement Greeter.greet
    let throughEnglish = EnglishGreeter().greet()      // onto the implementation EnglishGreeter.greet
    let throughFrench = FrenchGreeter().greet()         // onto the implementation FrenchGreeter.greet
    return throughRequirement + throughEnglish + throughFrench
}

/// A requirement with argument labels: stored in the index as `parse(_:referenceDate:)`. The bare
/// name `parse` never matches exactly — this is the class of symbol that broke before the fix.
public protocol Parser {
    func parse(_ text: String, referenceDate: Int) -> Int
}

public struct RuleParser: Parser {
    public init() {}
    public func parse(_ text: String, referenceDate: Int) -> Int { text.count + referenceDate }
}

public func runParser() -> Int {
    let viaProtocol: Parser = RuleParser()
    return viaProtocol.parse("x", referenceDate: 1) + RuleParser().parse("y", referenceDate: 2)
}

/// A closure property (indexed) versus a closure parameter (a local), plus a static method.
public struct Button {
    public let onTap: () -> Void
    public init(onTap: @escaping () -> Void) { self.onTap = onTap }
}

public func render(handler onEvent: () -> Void) { onEvent() }

public enum IDMaker {
    public static func make() -> Int { 42 }
}

public func useButton() {
    let b = Button(onTap: { _ = IDMaker.make() })
    b.onTap()
    render(handler: { })
}

/// Cross-language call sites. The index holds `ocGreetWithName:` under its Objective-C
/// selector spelling; the Swift call below reads `ocGreet(withName:)` and resolves to the same
/// symbol. Resolving it by the bare name `ocGreetWithName` is what the selector clause in
/// `IndexStore.resolveOccurrences` exists for.
public func useObjC() -> String {
    let greeter = OCGreeter()
    return greeter.ocGreet(withName: "x") + "\(OCGreeter.ocDefaultCount())"
}
