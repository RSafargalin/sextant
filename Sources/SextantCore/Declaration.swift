import Foundation

/// Access level of a declaration.
public enum Access: Int, Sendable, Comparable, Codable {
    case `private` = 0
    case `internal` = 1
    case `public` = 2

    public static func < (lhs: Access, rhs: Access) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The keyword as it is written in source. `fileprivate` is folded into `private` upstream.
    public var keyword: String {
        switch self {
        case .private: return "private"
        case .internal: return "internal"
        case .public: return "public"
        }
    }
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
    case associatedtypeKind = "associatedtype"
    case macroKind = "macro"
    case operatorKind = "operator"
    case precedenceGroupKind = "precedencegroup"

    /// Whether the declaration is a container type, and so can have members.
    public var isType: Bool {
        switch self {
        case .structKind, .classKind, .enumKind, .protocolKind, .actorKind, .extensionKind:
            return true
        case .function, .property, .initializer, .typealiasKind, .subscriptKind, .caseKind,
             .associatedtypeKind, .macroKind, .operatorKind, .precedenceGroupKind:
            return false
        }
    }
}

/// A declaration in source: one-line signature, attributes, doc summary, and nested members.
public struct Declaration: Sendable, Codable {
    public let kind: DeclarationKind
    /// The one-line signature without the access level: the modifiers that are part of the
    /// contract (`open`, `final`, `mutating`, a setter's access such as `private(set)`), the
    /// keyword, the name, and everything after it up to the body — generic clauses, parameters,
    /// effects, the result, `where`, a typealias's right-hand side, a property's accessors.
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
    /// The declared name: `Box` for `struct Box<T>`, `B` for `extension A.B`, `init` for an
    /// initializer, the selector for an Objective-C method. Used by the `api --type` filter and to
    /// match declarations across revisions.
    public let name: String

    public init(
        kind: DeclarationKind,
        header: String,
        access: Access,
        attributes: [String] = [],
        docSummary: String? = nil,
        members: [Declaration] = [],
        condition: String? = nil,
        name: String? = nil
    ) {
        self.kind = kind
        self.header = header
        self.access = access
        self.attributes = attributes
        self.docSummary = docSummary
        self.members = members
        self.condition = condition
        self.name = name ?? Self.name(kind: kind, header: header)
    }

    /// The same declaration with some of its parts replaced.
    func with(header: String? = nil, access: Access? = nil, members: [Declaration]? = nil,
              condition: String? = nil, name: String? = nil) -> Declaration {
        Declaration(kind: kind, header: header ?? self.header, access: access ?? self.access,
                    attributes: attributes, docSummary: docSummary, members: members ?? self.members,
                    condition: condition ?? self.condition, name: name ?? self.name)
    }

    /// The access keyword as a diff shows it. `open` is written in the header, where it replaces
    /// `public` rather than following it.
    private var accessPrefix: String {
        header.hasPrefix("open ") ? "" : "\(access.keyword) "
    }

    /// What a diff compares: the access level, the attributes that are part of the contract, the
    /// header, and the condition guarding the declaration. Moving a declaration into
    /// `#if os(iOS)` does not touch its header but does remove it from every other platform, and
    /// adding `@available(*, deprecated)` or `@MainActor` changes what every caller may do; a diff
    /// that stayed quiet about either would be reporting less than happened. Attributes are
    /// compared as a set: their order is not part of the contract.
    public var signature: String {
        let contract = attributes.filter(Self.isContractAttribute).sorted()
        let decorated = contract.isEmpty ? header : contract.joined(separator: " ") + " " + header
        let base = "\(accessPrefix)\(decorated)"
        return condition.map { "\(base)  [\($0)]" } ?? base
    }

    /// Whether an attribute changes what a user of the declaration can do. The exceptions are
    /// optimisation hints, which change how a declaration is compiled and nothing about its use.
    static func isContractAttribute(_ attribute: String) -> Bool {
        let name = attribute.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return !["inline", "_optimize", "_effects", "_semantics"].contains(String(name))
    }

    /// Header as a diff renders it: the access level included, because narrowing it removes the
    /// declaration from every other module while the rest of the line stays identical.
    public var diffHeader: String {
        let base = attributes.isEmpty ? header : attributes.joined(separator: " ") + " " + header
        let withAccess = "\(accessPrefix)\(base)"
        return condition.map { "\(withAccess)  [\($0)]" } ?? withAccess
    }

    /// Header prefixed with its attributes, for rendering.
    public var decoratedHeader: String {
        let base = attributes.isEmpty ? header : attributes.joined(separator: " ") + " " + header
        return condition.map { "\(base)  [\($0)]" } ?? base
    }

    /// The protocols and superclass an `extension` header adds (`extension Foo: Bar, Baz` →
    /// `["Bar", "Baz"]`), and the type it extends. Empty for every other declaration.
    var extensionParts: (extendedType: String, conformances: [String]) {
        guard kind == .extensionKind, header.hasPrefix("extension ") else { return ("", []) }
        let rest = String(header.dropFirst("extension ".count))
        let beforeWhere = Self.topLevelPrefix(of: rest, endingAt: " where ")
        guard let colon = Self.topLevelIndex(of: ":", in: beforeWhere) else {
            return (beforeWhere.trimmingCharacters(in: .whitespaces), [])
        }
        let extended = String(beforeWhere[..<colon]).trimmingCharacters(in: .whitespaces)
        let list = String(beforeWhere[beforeWhere.index(after: colon)...])
        return (extended, Self.splitTopLevel(list, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Declaration name from its header ("struct Box<T>: Foo" → "Box"; "extension A.B" → "B";
    /// "func parse(_:) …" → "parse"), for a declaration built without one.
    static func name(kind: DeclarationKind, header: String) -> String {
        // In a header, init and subscript are glued to `(` rather than being separate tokens, so
        // there is no name as such.
        switch kind {
        case .initializer: return "init"
        case .subscriptKind: return "subscript"
        case .caseKind where header.hasPrefix("case "):
            // A case list is every case it declares: `case a, b(x: Int)` → `a, b`.
            return splitTopLevel(String(header.dropFirst("case ".count)), separator: ",").map { element in
                element.trimmingCharacters(in: .whitespaces)
                    .prefix { $0 != "(" && $0 != " " && $0 != "=" }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            }.filter { !$0.isEmpty }.joined(separator: ", ")
        default: break
        }
        let tokens = header.split(separator: " ")
        // The token right after the kind keyword — robust against leading modifiers. A property
        // is introduced by `var` or `let`.
        let keywords: Set<Substring> = kind == .property ? ["var", "let"] : [Substring(kind.rawValue)]
        let afterKind: Substring
        if let kindIndex = tokens.firstIndex(where: keywords.contains), kindIndex + 1 < tokens.count {
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

    // MARK: - Reading headers

    /// Splits text at a separator that is outside brackets and string literals.
    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = [], current = ""
        scanTopLevel(text) { character, topLevel in
            if topLevel, character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            return true
        }
        parts.append(current)
        return parts
    }

    /// The first occurrence of a character outside brackets and string literals.
    static func topLevelIndex(of target: Character, in text: String) -> String.Index? {
        var offset = 0, found: Int?
        scanTopLevel(text) { character, topLevel in
            if topLevel, character == target { found = offset; return false }
            offset += 1
            return true
        }
        return found.map { text.index(text.startIndex, offsetBy: $0) }
    }

    /// The text before the first top-level occurrence of a marker, or all of it.
    static func topLevelPrefix(of text: String, endingAt marker: String) -> String {
        var prefix = ""
        scanTopLevel(text) { character, topLevel in
            if topLevel, (prefix + String(character)).hasSuffix(marker) {
                prefix.removeLast(marker.count - 1)
                return false
            }
            prefix.append(character)
            return true
        }
        return prefix
    }

    /// Walks the characters, telling for each whether it sits outside `()`, `[]`, `<>`, `{}` and
    /// string literals; an outermost bracket itself counts as outside. `->` is not a closing angle bracket. The body returns false to stop.
    private static func scanTopLevel(_ text: String, _ body: (Character, Bool) -> Bool) {
        var depth = 0, inString = false, escaped = false, previous: Character = " "
        for character in text {
            var topLevel = false
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "(", "[", "{", "<":
                    topLevel = depth == 0
                    depth += 1
                case ")", "]", "}":
                    depth = max(0, depth - 1)
                    topLevel = depth == 0
                case ">" where previous != "-":
                    depth = max(0, depth - 1)
                    topLevel = depth == 0
                default: topLevel = depth == 0
                }
            }
            if !body(character, topLevel) { return }
            previous = character
        }
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case kind, header, access, attributes, docSummary, members, condition, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try container.decode(DeclarationKind.self, forKey: .kind),
                  header: try container.decode(String.self, forKey: .header),
                  access: try container.decode(Access.self, forKey: .access),
                  attributes: try container.decode([String].self, forKey: .attributes),
                  docSummary: try container.decodeIfPresent(String.self, forKey: .docSummary),
                  members: try container.decode([Declaration].self, forKey: .members),
                  condition: try container.decodeIfPresent(String.self, forKey: .condition),
                  name: try container.decodeIfPresent(String.self, forKey: .name))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(header, forKey: .header)
        try container.encode(access, forKey: .access)
        try container.encode(attributes, forKey: .attributes)
        try container.encodeIfPresent(docSummary, forKey: .docSummary)
        try container.encode(members, forKey: .members)
        try container.encodeIfPresent(condition, forKey: .condition)
        try container.encode(name, forKey: .name)
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
