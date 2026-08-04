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
}
