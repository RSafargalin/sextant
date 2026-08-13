import IndexStoreDB

/// Position of a symbol occurrence in the sources.
public struct SourceLocation: Hashable, Sendable, Codable {
    public let path: String
    public let line: Int
    public let column: Int
    public let isDefinition: Bool

    init(_ occurrence: SymbolOccurrence) {
        self.path = occurrence.location.path
        self.line = occurrence.location.line
        self.column = occurrence.location.utf8Column
        self.isDefinition = occurrence.roles.contains(.definition)
    }

    init(path: String, line: Int, column: Int, isDefinition: Bool) {
        self.path = path
        self.line = line
        self.column = column
        self.isDefinition = isDefinition
    }

    /// Deterministic ordering: path, then line, then column.
    static func isOrderedBefore(_ lhs: SourceLocation, _ rhs: SourceLocation) -> Bool {
        (lhs.path, lhs.line, lhs.column) < (rhs.path, rhs.line, rhs.column)
    }
}

/// A related symbol — a callee, a protocol implementation, or a subtype — with its position.
public struct RelatedSymbol: Sendable, Codable {
    public let name: String
    public let usr: String
    public let kind: String
    public let location: SourceLocation

    public init(name: String, usr: String, kind: String, location: SourceLocation) {
        self.name = name
        self.usr = usr
        self.kind = kind
        self.location = location
    }
}

/// A resolved symbol: its definition and its usages.
public struct SymbolHit: Sendable, Codable {
    public let name: String
    public let usr: String
    public let kind: String
    public let definition: SourceLocation?
    public let references: [SourceLocation]
    /// How many references the index held before the internal cap. Equal to `references.count`
    /// when nothing was dropped; larger when it was, so the answer can say so instead of
    /// presenting the cap as the total.
    public let totalReferences: Int

    public init(name: String, usr: String, kind: String, definition: SourceLocation?,
                references: [SourceLocation], totalReferences: Int? = nil) {
        self.name = name
        self.usr = usr
        self.kind = kind
        self.definition = definition
        self.references = references
        self.totalReferences = totalReferences ?? references.count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        usr = try container.decode(String.self, forKey: .usr)
        kind = try container.decode(String.self, forKey: .kind)
        definition = try container.decodeIfPresent(SourceLocation.self, forKey: .definition)
        references = try container.decode([SourceLocation].self, forKey: .references)
        totalReferences = try container.decodeIfPresent(Int.self, forKey: .totalReferences) ?? references.count
    }
}
