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
    /// Where the symbol is defined. For a call hierarchy this is the definition of the callee or
    /// of the caller — not the place the call was written, which is `callSite`. The two used to be
    /// the same field, so a hierarchy pointed at the line a function was called from and called it
    /// the function: `timestamp(ofStore:)` was shown at line 48 while it is defined at line 25,
    /// and nothing in the answer said which of the two it meant.
    public let location: SourceLocation
    /// Where the call was written. `nil` for relations that are not calls (implementations).
    public let callSite: SourceLocation?
    /// False when the index does not hold the definition — an external or system symbol — and
    /// `location` is standing in for it with the call site. Saying so is the difference between a
    /// missing fact and a wrong one.
    public let definitionKnown: Bool

    public init(name: String, usr: String, kind: String, location: SourceLocation,
                callSite: SourceLocation? = nil, definitionKnown: Bool = true) {
        self.name = name
        self.usr = usr
        self.kind = kind
        self.location = location
        self.callSite = callSite
        self.definitionKnown = definitionKnown
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
