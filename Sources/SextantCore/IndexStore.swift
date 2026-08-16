import Foundation
import IndexStoreDB

/// Kind of semantic query about a symbol.
public enum SymbolQuery: Sendable {
    case definitions
    case references
    case callers

    var roles: SymbolRole {
        switch self {
        case .definitions: return .definition
        case .references: return .reference
        case .callers: return .call
        }
    }
}

/// Kind of related-symbol query, resolved through the index relations.
public enum RelationQuery: Sendable {
    case callees         // what the symbol calls (relation .calledBy)
    case implementations // implementations and subtypes of a protocol or class (down the hierarchy)
    case supertypes      // bases and protocols of a type (up the hierarchy)
}

/// Direction of traversal through the call graph.
public enum CallDirection: Sendable {
    case callees
    case callers
}

/// Reads the compiler's semantic index (the index store) through IndexStoreDB.
public final class IndexStore {
    let database: IndexStoreDB
    /// Resolved project root used to scope results (nil means no scoping). It excludes other
    /// worktrees: a shared DerivedData store accumulates units from neighbouring `.claude/worktrees/*`.
    private let projectScope: String?

    public init(storePath: String, libraryPath: String, databasePath: String, listenToUnitEvents: Bool = false, projectRoot: String? = nil) throws {
        let library = try IndexStoreLibrary(dylibPath: libraryPath)
        self.database = try IndexStoreDB(
            storePath: storePath,
            databasePath: databasePath,
            library: library,
            waitUntilDoneInitializing: true,
            listenToUnitEvents: listenToUnitEvents
        )
        self.projectScope = projectRoot.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// Synchronously reads newly written unit files (reindexing on a hot store) — for a long-lived server.
    public func pollForChanges() {
        database.pollForUnitChangesAndWait()
    }

    /// Resolves a name to occurrences. A prefix search filtered by three shapes, because the
    /// index stores a symbol under the spelling of the language that declared it:
    ///
    /// - `== name` — types, and methods that take no arguments (`defaultCount`);
    /// - `name(` — Swift methods, stored with argument labels: `parse(_:referenceDate:)`,
    ///   so a bare method name never matches exactly;
    /// - `name:` — Objective-C methods, stored as selectors: `greetWithName:`. A Swift call
    ///   spelled `greet(withName:)` resolves to that same symbol, so cross-language callers
    ///   work once the name matches.
    ///
    /// A prefix search is a superset of an exact one, so one query covers all three.
    /// Short-circuiting on `ofName` was a bug: one irrelevant exact symbol hid the real
    /// methods, such as `parse` and `validate`.
    private func resolveOccurrences(forName name: String) -> [SymbolOccurrence] {
        database
            .canonicalOccurrences(containing: name, anchorStart: true, anchorEnd: false, subsequence: false, ignoreCase: false)
            .filter {
                $0.symbol.name == name
                    || $0.symbol.name.hasPrefix("\(name)(")
                    || $0.symbol.name.hasPrefix("\(name):")
            }
    }

    /// Records the store holds for a name that the scope filter rejected, and the foreign roots
    /// they belong to.
    ///
    /// Without this, a store built from another checkout produces zero hits and the answer explains
    /// them away — "a closure, a local, or another kind of symbol" — about a class the index knows
    /// perfectly well. The store is not silent about the symbol; it is describing someone else's
    /// copy of it, and that is what has to be said.
    public func outOfScope(forName name: String) -> (count: Int, roots: Set<String>) {
        var count = 0
        var roots: Set<String> = []
        for occurrence in resolveOccurrences(forName: name) where !isInScope(occurrence.location) {
            guard Self.isProjectSource(occurrence.location) else { continue }
            count += 1
            let path = URL(fileURLWithPath: occurrence.location.path).resolvingSymlinksInPath().path
            if let worktree = Self.worktreePrefix(of: path) { roots.insert(worktree) }
        }
        return (count, roots)
    }

    /// Symbols with the given name: the definition plus occurrences of the requested kind.
    public func lookup(name: String, query: SymbolQuery, limit: Int = 1000) -> [SymbolHit] {
        let definitions = resolveOccurrences(forName: name)

        var definitionByUSR: [String: SymbolOccurrence] = [:]
        for occurrence in definitions where occurrence.roles.contains(.definition) && isInScope(occurrence.location) {
            definitionByUSR[occurrence.symbol.usr] = occurrence
        }
        if definitionByUSR.isEmpty {
            for occurrence in definitions where isInScope(occurrence.location) {
                definitionByUSR[occurrence.symbol.usr] = occurrence
            }
        }

        return definitionByUSR.map { usr, definitionOccurrence in
            // For callers, account for protocol dispatch: calls land on the requirement that
            // the method overrides (relation .overrideOf), so its call sites are added too.
            var usrsToQuery = [usr]
            if query == .callers {
                for occurrence in database.occurrences(ofUSR: usr, roles: .overrideOf) {
                    for relation in occurrence.relations where relation.roles.contains(.overrideOf) {
                        usrsToQuery.append(relation.symbol.usr)
                    }
                }
            }
            var seen = Set<String>()
            var locations: [SourceLocation] = []
            for queryUSR in usrsToQuery {
                for occurrence in database.occurrences(ofUSR: queryUSR, roles: query.roles) where isInScope(occurrence.location) {
                    let location = SourceLocation(occurrence)
                    if seen.insert("\(location.path):\(location.line):\(location.column)").inserted {
                        locations.append(location)
                    }
                }
            }
            // The canonical occurrence is not always the definition: in Objective-C and C it is
            // the declaration in the header, while the definition lives in the .m or .c. Ask the
            // database for the definition by USR rather than leaving the field empty.
            //
            // What is deliberately NOT done is falling back to any occurrence at all: that would
            // pass a plain use off as a definition, which is the failure this whole layer exists
            // to avoid.
            let definitionLocation: SourceLocation? = definitionOccurrence.roles.contains(.definition)
                ? SourceLocation(definitionOccurrence)
                : database.occurrences(ofUSR: usr, roles: .definition)
                    .first { isInScope($0.location) }
                    .map(SourceLocation.init)

            // A macro records the same reference twice — where it is written and where it was
            // expanded from — so the positions the source does not carry are dropped before
            // anything is counted.
            let carried = ReferencePositions.verified(locations, name: definitionOccurrence.symbol.name)
            return SymbolHit(
                name: definitionOccurrence.symbol.name,
                usr: usr,
                kind: "\(definitionOccurrence.symbol.kind)",
                definition: definitionLocation,
                references: Array(carried.sorted(by: SourceLocation.isOrderedBefore).prefix(limit)),
                totalReferences: carried.count
            )
        }
        .sorted { $0.usr < $1.usr }
    }

    /// Related symbols for a name (callees, implementations) through the index relations.
    public func related(toName name: String, query: RelationQuery, limit: Int = 1000) -> [RelatedSymbol] {
        let definitions = resolveOccurrences(forName: name)
        var usrs = Set<String>()
        for occurrence in definitions where occurrence.roles.contains(.definition) && isInScope(occurrence.location) {
            usrs.insert(occurrence.symbol.usr)
        }
        if usrs.isEmpty {
            for occurrence in definitions where isInScope(occurrence.location) { usrs.insert(occurrence.symbol.usr) }
        }

        var seen = Set<String>()
        var results: [RelatedSymbol] = []
        func add(_ symbol: Symbol, at location: SourceLocation) {
            let key = "\(symbol.usr)|\(location.path):\(location.line):\(location.column)"
            guard seen.insert(key).inserted else { return }
            results.append(RelatedSymbol(name: symbol.name, usr: symbol.usr, kind: "\(symbol.kind)", location: location))
        }

        for usr in usrs.sorted() {
            switch query {
            case .callees:
                // symbols called by this one: occurrence.symbol is the callee.
                for occurrence in database.occurrences(relatedToUSR: usr, roles: .calledBy) where isInScope(occurrence.location) {
                    add(occurrence.symbol, at: SourceLocation(occurrence))
                }
            case .implementations:
                // types for which this protocol or class is a base: the subtype is in relation.symbol.
                for occurrence in database.occurrences(ofUSR: usr, roles: .baseOf) where isInScope(occurrence.location) {
                    for relation in occurrence.relations where relation.roles.contains(.baseOf) {
                        add(relation.symbol, at: SourceLocation(occurrence))
                    }
                }
            case .supertypes:
                // bases and protocols of this type: occurrence.symbol is the base.
                for occurrence in database.occurrences(relatedToUSR: usr, roles: .baseOf) where isInScope(occurrence.location) {
                    add(occurrence.symbol, at: SourceLocation(occurrence))
                }
            }
        }
        return Array(results.sorted { SourceLocation.isOrderedBefore($0.location, $1.location) }.prefix(limit))
    }

    /// Root symbols for a name (used by the call hierarchy): definitions with a USR.
    public func resolveSymbols(forName name: String) -> [RelatedSymbol] {
        var seen = Set<String>()
        var results: [RelatedSymbol] = []
        for occurrence in resolveOccurrences(forName: name)
        where occurrence.roles.contains(.definition) && isInScope(occurrence.location) {
            guard seen.insert(occurrence.symbol.usr).inserted else { continue }
            results.append(RelatedSymbol(name: occurrence.symbol.name, usr: occurrence.symbol.usr, kind: "\(occurrence.symbol.kind)", location: SourceLocation(occurrence)))
        }
        return results
    }

    /// Project symbol names by prefix (for resource-template completion). Bare names without
    /// argument labels (`parse`, not `parse(_:referenceDate:)`), deduplicated, scoped to the project.
    public func symbolNames(matchingPrefix prefix: String, limit: Int = 50) -> [String] {
        // A one-character prefix on a large index means a mass scan plus an isInScope syscall for
        // each hit, which blocks the sequential MCP loop. A minimum of 2 plus a scan cap bound it.
        guard prefix.count >= 2 else { return [] }
        let scanCap = max(2000, limit * 20)
        var names = Set<String>()
        var scanned = 0
        for occurrence in database.canonicalOccurrences(
            containing: prefix, anchorStart: true, anchorEnd: false, subsequence: false, ignoreCase: false
        ) {
            scanned += 1
            if scanned > scanCap || names.count >= limit * 4 { break }
            guard isInScope(occurrence.location) else { continue }
            let name = occurrence.symbol.name
            let bare = name.contains("(") ? String(name.prefix { $0 != "(" }) : name
            if bare.hasPrefix(prefix) { names.insert(bare) }
        }
        return Array(names.sorted().prefix(limit))
    }

    /// Direct callees or callers of a symbol by USR (one level) — used by the recursive hierarchy.
    ///
    /// One entry per symbol, not per call site. A hierarchy edge is "calls this", so a method
    /// called twice on one line used to appear as two identical children and to spend the
    /// breadth budget twice over.
    public func calls(ofUSR usr: String, direction: CallDirection) -> [RelatedSymbol] {
        var sites: [RelatedSymbol] = []
        // The occurrence is where the call was written; the symbol it names lives somewhere else.
        // Asking the database for the definition by USR is the same route `lookup` takes, and it
        // is what keeps a hierarchy from pointing at a call site and calling it a definition.
        func add(_ symbol: Symbol, callSite: SourceLocation) {
            let definition = database.occurrences(ofUSR: symbol.usr, roles: .definition)
                .first { isInScope($0.location) }
                .map(SourceLocation.init)
            sites.append(RelatedSymbol(name: symbol.name, usr: symbol.usr, kind: "\(symbol.kind)",
                                       location: definition ?? callSite, callSite: callSite,
                                       definitionKnown: definition != nil))
        }
        switch direction {
        case .callees:
            for occurrence in database.occurrences(relatedToUSR: usr, roles: .calledBy) where isInScope(occurrence.location) {
                add(occurrence.symbol, callSite: SourceLocation(occurrence))
            }
        case .callers:
            for occurrence in database.occurrences(ofUSR: usr, roles: .call) where isInScope(occurrence.location) {
                for relation in occurrence.relations where relation.roles.contains(.calledBy) {
                    add(relation.symbol, callSite: SourceLocation(occurrence))
                }
            }
        }
        // Sorted by call site before deduplication, so the entry kept for a symbol is its first
        // call rather than whichever one the store happened to return first.
        var seen = Set<String>()
        return sites
            .sorted { SourceLocation.isOrderedBefore($0.callSite ?? $0.location, $1.callSite ?? $1.location) }
            .filter { seen.insert($0.usr).inserted }
    }

    /// A project source within the current project's scope: not SDK or vendored code, and (when a
    /// root is given) under that root but not inside a foreign nested worktree.
    private func isInScope(_ location: SymbolLocation) -> Bool {
        guard Self.isProjectSource(location) else { return false }
        guard let root = projectScope else { return true }
        // Resolve the path the same way as the root: the index records paths as the compiler saw
        let path = URL(fileURLWithPath: location.path).resolvingSymlinksInPath().path
        return Self.inScope(path: path, root: root)
    }

    /// A project source: not SDK code and not a vendored dependency under .build/checkouts.
    private static func isProjectSource(_ location: SymbolLocation) -> Bool {
        !location.isSystem
            && !location.path.contains("/.build/")
            && !location.path.contains("/checkouts/")
    }

    /// Path within the project scope. Non-worktree paths are ALWAYS allowed, to avoid
    /// over-filtering — a foreign `--index-store` must not be silently emptied. A worktree-nested
    /// path (`.../.claude/worktrees/<name>/…`) passes only if the root is inside that same worktree.
    /// So the main checkout excludes every nested worktree, while a worktree admits its own files.
    static func inScope(path: String, root: String) -> Bool {
        guard let worktree = worktreePrefix(of: path) else { return true }
        return root == worktree || root.hasPrefix(worktree + "/")
    }

    /// Prefix up to and including `.claude/worktrees/<name>`, when the path is inside such a worktree.
    static func worktreePrefix(of path: String) -> String? {
        let marker = "/.claude/worktrees/"
        guard let range = path.range(of: marker) else { return nil }
        let name = path[range.upperBound...].prefix { $0 != "/" }
        guard !name.isEmpty else { return nil }
        return String(path[..<range.upperBound]) + name
    }
}
