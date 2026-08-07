import Foundation

/// Access level of a declaration.
public enum Access: Int, Sendable, Comparable, Codable {
    case `private` = 0
    case `internal` = 1
    case `public` = 2

    public static func < (lhs: Access, rhs: Access) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Kind of declaration.
public enum DeclarationKind: String, Sendable, Codable {
    case structKind = "struct"
    case classKind = "class"
    case enumKind = "enum"
    case protocolKind = "protocol"
    case actorKind = "actor"
    case extensionKind = "extension"
    case function = "func"
    case property = "var"
    case initializer = "init"
    case typealiasKind = "typealias"
    case subscriptKind = "subscript"
    case caseKind = "case"

    /// Whether the declaration is a container type, and so can have members.
    public var isType: Bool {
        switch self {
        case .structKind, .classKind, .enumKind, .protocolKind, .actorKind, .extensionKind:
            return true
        case .function, .property, .initializer, .typealiasKind, .subscriptKind, .caseKind:
            return false
        }
    }
}

/// A declaration in source: one-line signature, attributes, doc summary, and nested members.
public struct Declaration: Sendable, Codable {
    public let kind: DeclarationKind
    public let header: String
    public let access: Access
    public let attributes: [String]
    public let docSummary: String?
    public let members: [Declaration]
    /// The conditional compilation the declaration is guarded by (`#if os(iOS)`, `#else`), when
    /// it is. Kept out of `header` so that identity does not change, and shown in every rendering:
    /// a declaration that exists only on another platform is part of the surface, and hiding that
    /// it is conditional would be the same lie as hiding the declaration.
    public let condition: String?

    public init(
        kind: DeclarationKind,
        header: String,
        access: Access,
        attributes: [String] = [],
        docSummary: String? = nil,
        members: [Declaration] = [],
        condition: String? = nil
    ) {
        self.kind = kind
        self.header = header
        self.access = access
        self.attributes = attributes
        self.docSummary = docSummary
        self.members = members
        self.condition = condition
    }

    /// Header prefixed with its attributes, for rendering.
    /// What a diff compares: the signature plus the condition guarding it. Moving a declaration
    /// into `#if os(iOS)` does not touch its header but does remove it from every other platform,
    /// and a diff that stayed quiet about that would be reporting less than happened.
    public var signature: String {
        condition.map { "\(header)  [\($0)]" } ?? header
    }

    public var decoratedHeader: String {
        let base = attributes.isEmpty ? header : attributes.joined(separator: " ") + " " + header
        return condition.map { "\(base)  [\($0)]" } ?? base
    }

    /// Declaration name from its header ("public struct Box<T>: Foo" → "Box"; "extension A.B" → "B";
    /// "func parse(_:) …" → "parse"). Used by the `api --type` filter and for addressing.
    public var name: String {
        // In a header, init and subscript are glued to `(` rather than being separate tokens, so
        // there is no name as such.
        switch kind {
        case .initializer: return "init"
        case .subscriptKind: return "subscript"
        default: break
        }
        let tokens = header.split(separator: " ")
        // The token right after the kind keyword — robust against leading access modifiers.
        let afterKind: Substring
        if let kindIndex = tokens.firstIndex(of: Substring(kind.rawValue)), kindIndex + 1 < tokens.count {
            afterKind = tokens[kindIndex + 1]
        } else {
            afterKind = tokens.dropFirst().first ?? ""
        }
        let withoutInheritance = afterKind.split(separator: ":").first ?? afterKind
        let withoutGenerics = withoutInheritance.split(separator: "<").first ?? withoutInheritance
        let withoutParen = withoutGenerics.split(separator: "(").first ?? withoutGenerics
        let withoutComma = withoutParen.split(separator: ",").first ?? withoutParen   // `case a, b` → a
        let lastComponent = withoutComma.split(separator: ".").last ?? withoutComma
        return lastComponent.trimmingCharacters(in: CharacterSet(charactersIn: "` ")).trimmingCharacters(in: .whitespaces)
    }
}

/// Summary of one file: its path, package, and top-level declarations.
public struct FileSummary: Sendable, Codable {
    public let relativePath: String
    public let package: String
    public let declarations: [Declaration]

    public init(relativePath: String, package: String, declarations: [Declaration]) {
        self.relativePath = relativePath
        self.package = package
        self.declarations = declarations
    }
}
