import Foundation
import SwiftParser
import SwiftSyntax

/// Line-level correspondence between two versions of a file.
enum LineDiff {
    /// For every line of `old` (0-based), the line of `new` that holds the same text as part of a
    /// shortest edit script, or nil when the line was modified or deleted. The common prefix and
    /// suffix are matched directly, so an edit in one place costs a pass over the file; the middle
    /// is matched by `CollectionDifference` (Myers) over interned lines.
    static func map(old: [String], new: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: old.count)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            result[prefix] = prefix
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            result[old.count - 1 - suffix] = new.count - 1 - suffix
            suffix += 1
        }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        guard prefix < oldEnd, prefix < newEnd else { return result }

        var ids: [String: Int] = [:]
        func intern(_ line: String) -> Int {
            if let id = ids[line] { return id }
            let id = ids.count
            ids[line] = id
            return id
        }
        let oldMiddle = old[prefix..<oldEnd].map(intern)
        let newMiddle = new[prefix..<newEnd].map(intern)
        let difference = newMiddle.difference(from: oldMiddle)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var newIndex = 0
        for oldIndex in 0..<oldMiddle.count where !removed.contains(oldIndex) {
            while inserted.contains(newIndex) { newIndex += 1 }
            result[prefix + oldIndex] = prefix + newIndex
            newIndex += 1
        }
        return result
    }
}

/// What a stale index's answer needs beyond the answer itself: the files that changed since the
/// store was built, the ones among them whose declarations changed, and the places the name is
/// now written that the index does not confirm.
public struct Staleness: Sendable, Codable, Equatable {
    /// A text match of the name in a changed file that no index occurrence confirms: same name,
    /// possibly another symbol.
    public struct Candidate: Sendable, Codable, Equatable {
        public let path: String
        public let line: Int
        public let column: Int
        public let text: String
    }

    /// Sources changed since the store was built, relative to the project root.
    public let changedFiles: [String]
    /// The changed files whose declarations changed (added, removed, signature), or that could not
    /// be compared — uses elsewhere may resolve differently now. A changed C-family header counts.
    public let declarationsChanged: [String]
    /// Text matches of the name in changed files, up to a bound.
    public let candidates: [Candidate]
    /// How many text matches there were before the bound.
    public let candidateCount: Int
    /// How the matches were found.
    public let candidateMatching: String

    /// The same note with only the listed candidates that satisfy `keep`, counted as listed.
    public func keepingCandidates(where keep: (Candidate) -> Bool) -> Staleness {
        let kept = candidates.filter(keep)
        return Staleness(changedFiles: changedFiles, declarationsChanged: declarationsChanged,
                         candidates: kept, candidateCount: kept.count, candidateMatching: candidateMatching)
    }

    public static let matching = "identifier tokens in Swift (not comments or string literals); "
        + "lexical identifiers outside comments and literals in Objective-C, C and C++"
}

/// The sources as they are now against the text a stale index was built from, for the files that
/// changed. It consumes the report `IndexFreshness` gave on the snapshot basis and judges nothing
/// again: it maps positions the index recorded onto the current text, says which cannot be mapped,
/// finds where the name is written now that the index does not know, and tells changed
/// declarations from changed bodies.
///
/// Built per request; the texts it reads are cached for that request only.
public final class IndexDrift: @unchecked Sendable {
    /// Why a position is unconfirmed, as `SourceLocation.unconfirmed` carries it.
    public enum Reason {
        public static let lineChanged = "line-changed"
        public static let fileDeleted = "file-deleted"
        public static let noIndexedText = "no-indexed-text"
    }

    /// How many candidates one answer lists.
    public static let candidateLimit = 100
    /// How many changed files have their declarations compared; the rest are counted as changed.
    public static let classificationLimit = 50

    public let report: IndexFreshness.Report
    /// The canonical project root, the one changed files are compared under.
    let root: String
    /// The project root as the caller spells it, which is how paths in answers are spelled.
    private let spelledRoot: String
    private let changed: Set<String>
    private let home: URL
    private let git: SourceSnapshot.GitRunner
    private let lock = NSLock()
    private var currents: [String: CurrentText] = [:]
    private var states: [String: FileState] = [:]
    private var relativePaths: [String: String?] = [:]
    private var classified: [String]?
    private var notes: [String: Staleness] = [:]
    private var fetched: [String: Data]?
    private let makeClassificationCache: () -> PersistentCache<Bool>?
    private lazy var classificationCache: PersistentCache<Bool>? = makeClassificationCache()

    /// Where classifications of a pair of texts are kept across requests.
    public static func makeClassificationCache() -> PersistentCache<Bool> {
        PersistentCache<Bool>(namespace: CacheNamespace.driftDeclarations)
    }

    /// A changed file as it is now; nil text when it is gone.
    private struct CurrentText {
        let source: String?
        let lines: [String]?
    }

    private struct FileState {
        /// The text the store was built from; nil when the file did not exist then or the text is
        /// not available.
        let indexed: [String]?
        let indexedSource: String?
        /// Whether the file existed when the store was built.
        let existedAtIndexing: Bool
        /// The text now; nil when the file is gone.
        let current: [String]?
        let currentSource: String?
        /// Old line → new line, when both texts are known.
        let map: [Int?]?
    }

    /// nil unless the report is on the snapshot basis and names changed files: on the build-time
    /// basis nothing is known about what changed, and with nothing changed there is nothing to map.
    public init?(report: IndexFreshness.Report, projectRoot: String,
                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 git: SourceSnapshot.GitRunner = .system,
                 classificationCache: @escaping () -> PersistentCache<Bool>? = { IndexDrift.makeClassificationCache() }) {
        guard report.basis == .snapshot, !report.changedFiles.isEmpty else { return nil }
        self.makeClassificationCache = classificationCache
        self.report = report
        self.root = IndexSnapshot.canonical(projectRoot)
        // Candidates are spelled the way the store spells the files around them: by real path.
        self.spelledRoot = CanonicalPath.real(projectRoot)
        self.changed = Set(report.changedFiles)
        self.home = home
        self.git = git
    }

    // MARK: - Positions

    /// Whether the file is one of the changed files, the ones whose current text is not the text
    /// the index was built from.
    public func isChanged(_ path: String) -> Bool {
        changedRelativePath(of: path) != nil
    }

    /// The text a changed file was indexed from, line by line; nil for a file that did not change
    /// (its current text is its indexed text) or whose indexed text is unavailable.
    public func indexedLines(ofFile path: String) -> [String]? {
        guard let relative = changedRelativePath(of: path) else { return nil }
        return state(of: relative).indexed
    }

    /// The position stated against the current text: unchanged outside changed files; on a line
    /// the edit left intact, moved to where that line is now; otherwise kept as indexed and marked
    /// unconfirmed, never dropped. The column is carried as it is: a line that moved is unchanged,
    /// so the column restated against its indexed text holds on its current one.
    public func translate(_ location: SourceLocation) -> SourceLocation {
        guard let relative = changedRelativePath(of: location.path) else { return location }
        let state = state(of: relative)
        func unconfirmed(_ reason: String) -> SourceLocation {
            SourceLocation(path: location.path, line: location.line, column: location.column,
                           isDefinition: location.isDefinition, indexedLine: location.line, unconfirmed: reason)
        }
        guard state.current != nil else { return unconfirmed(Reason.fileDeleted) }
        guard let map = state.map else { return unconfirmed(Reason.noIndexedText) }
        let index = location.line - 1
        guard index >= 0, index < map.count, let now = map[index] else { return unconfirmed(Reason.lineChanged) }
        return SourceLocation(path: location.path, line: now + 1, column: location.column,
                              isDefinition: location.isDefinition, indexedLine: location.line)
    }

    /// The line a translated position was recorded on, as the index saw it.
    public func indexedLineText(of location: SourceLocation) -> String? {
        guard let line = location.indexedLine, let relative = changedRelativePath(of: location.path),
              let indexed = state(of: relative).indexed, line >= 1, line <= indexed.count else { return nil }
        return indexed[line - 1]
    }

    // MARK: - Candidates

    /// Places in changed files that exist now where `name` is written as an identifier and that
    /// none of `known` (positions the index confirms, already translated) accounts for. With
    /// `declarationsOnly`, Swift matches are limited to the names of declarations.
    func candidates(forName name: String, excluding known: @autoclosure () -> [SourceLocation], declarationsOnly: Bool)
        -> (shown: [Staleness.Candidate], total: Int) {
        let needle = Self.baseName(name)
        guard IdentifierScan.isIdentifier(needle) else { return ([], 0) }
        // Read only once some changed file is found to mention the name at all.
        var confirmedPositions: Set<String>?
        var found: [Staleness.Candidate] = []
        for relative in changed.sorted() {
            let now = current(of: relative)
            guard let source = now.source, let lines = now.lines, source.contains(needle) else { continue }
            // Every position the index states is accounted for, unconfirmed ones included: a text
            // match where the answer already lists a position is that position again, not a lead.
            let confirmed = confirmedPositions ?? Set(known().compactMap { location in
                location.column.flatMap { column in changedRelativePath(of: location.path).map { "\($0):\(location.line):\(column)" } }
            })
            confirmedPositions = confirmed
            // Every place the name is written as a whole word — comments and strings included, a
            // superset of the tokens — that the index already confirms leaves nothing to parse for.
            let written = Self.wholeWords(needle, in: lines)
            if written.allSatisfy({ confirmed.contains("\(relative):\($0.line):\($0.column)") }) { continue }
            let positions = relative.hasSuffix(".swift")
                ? Self.swiftIdentifiers(named: needle, in: source, declarationsOnly: declarationsOnly)
                : Self.lexicalIdentifiers(named: needle, in: source)
            for position in positions where !confirmed.contains("\(relative):\(position.line):\(position.column)") {
                let text = position.line <= lines.count ? lines[position.line - 1].trimmingCharacters(in: .whitespaces) : ""
                found.append(Staleness.Candidate(path: spelledRoot + "/" + relative, line: position.line,
                                                 column: position.column, text: text))
            }
        }
        return (Array(found.prefix(Self.candidateLimit)), found.count)
    }

    /// Positions (line, reported column) where `word` is written with identifier boundaries.
    static func wholeWords(_ word: String, in lines: [String]) -> [(line: Int, column: Int)] {
        let needle = Array(word.utf8)
        func isIdentifierByte(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: "_") || byte >= 0x80
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        }
        var result: [(line: Int, column: Int)] = []
        for (offset, line) in lines.enumerated() {
            let bytes = Array(line.utf8)
            guard bytes.count >= needle.count else { continue }
            var start = 0
            while start + needle.count <= bytes.count {
                if bytes[start] == needle[0], Array(bytes[start..<start + needle.count]) == needle,
                   start == 0 || !isIdentifierByte(bytes[start - 1]),
                   start + needle.count == bytes.count || !isIdentifierByte(bytes[start + needle.count]) {
                    result.append((offset + 1, SourceColumn.column(after: bytes[..<start])))
                    start += needle.count
                } else {
                    start += 1
                }
            }
        }
        return result
    }

    // MARK: - Declarations

    /// The changed files whose declarations changed, or which could not be compared.
    public var declarationsChanged: [String] {
        lock.lock()
        if let classified { lock.unlock(); return classified }
        let classificationCache = self.classificationCache
        lock.unlock()
        var result: [String] = []
        for (offset, relative) in changed.sorted().enumerated() {
            guard offset < Self.classificationLimit else { result.append(relative); continue }
            let now = current(of: relative)
            // Keyed by both contents: the same pair of texts always classifies the same way, so a
            // later query over the same edit does not parse them again.
            let key = "\((relative as NSString).pathExtension)|\(report.indexedContent[relative] ?? "-")|"
                + (now.source.map { SourceSnapshot.blobHash(of: Data($0.utf8)) } ?? "-")
            let differs: Bool
            if let cached = classificationCache?.value(forKey: key) {
                differs = cached
            } else {
                let state = state(of: relative)
                differs = Self.declarationsDiffer(indexed: state.indexedSource, current: state.currentSource ?? "",
                                                  path: relative, existed: state.existedAtIndexing)
                if state.indexedSource != nil || !state.existedAtIndexing { classificationCache?.set(differs, forKey: key) }
            }
            if differs { result.append(relative) }
        }
        lock.lock()
        classified = result
        lock.unlock()
        return result
    }

    /// Whether a file's declarations differ between its indexed and its current text. A header of
    /// the C family always counts, its other files never do; a Swift file counts when a declaration
    /// was added, removed or changed signature, and when either side cannot be compared.
    static func declarationsDiffer(indexed: String?, current: String, path: String, existed: Bool) -> Bool {
        let fileExtension = (path as NSString).pathExtension
        if IndexDeclarations.headerExtensions.contains(fileExtension) { return true }
        guard fileExtension == "swift" else { return false }
        let before: String
        if existed {
            guard let indexed else { return true }
            before = indexed
        } else {
            before = ""
        }
        let old = DeclarationDiff.parsed(before), new = DeclarationDiff.parsed(current)
        if old.recovered || new.recovered { return true }
        return !DeclarationDiff.compare(old: old.declarations, new: new.declarations).isEmpty
    }

    // MARK: - The note

    /// The staleness note for an answer about `name`.
    func note(forName name: String, known: @autoclosure () -> [SourceLocation], declarationsOnly: Bool) -> Staleness {
        let key = "\(declarationsOnly)|\(name)"
        lock.lock()
        if let cached = notes[key] { lock.unlock(); return cached }
        lock.unlock()
        let found = candidates(forName: name, excluding: known(), declarationsOnly: declarationsOnly)
        let note = Staleness(changedFiles: report.changedFiles, declarationsChanged: declarationsChanged,
                             candidates: found.shown, candidateCount: found.total,
                             candidateMatching: Staleness.matching)
        lock.lock()
        notes[key] = note
        lock.unlock()
        return note
    }

    // MARK: - Reading

    private func changedRelativePath(of path: String) -> String? {
        lock.lock()
        if let cached = relativePaths[path] { lock.unlock(); return cached }
        lock.unlock()
        let canonical = Self.canonicalPath(path)
        var relative: String?
        if canonical.hasPrefix(root + "/") {
            let candidate = String(canonical.dropFirst(root.count + 1))
            if changed.contains(candidate) { relative = candidate }
        }
        lock.lock()
        relativePaths[path] = relative
        lock.unlock()
        return relative
    }

    /// The current text alone, which candidates and a cached classification need: the indexed
    /// text costs a `git` process per file and is read only where a position must be mapped.
    private func current(of relative: String) -> CurrentText {
        lock.lock()
        if let cached = currents[relative] { lock.unlock(); return cached }
        lock.unlock()
        let source = FileManager.default.contents(atPath: root + "/" + relative).map { String(decoding: $0, as: UTF8.self) }
        let text = CurrentText(source: source, lines: source.map { $0.components(separatedBy: "\n") })
        lock.lock()
        currents[relative] = text
        lock.unlock()
        return text
    }

    private func state(of relative: String) -> FileState {
        lock.lock()
        if let cached = states[relative] { lock.unlock(); return cached }
        lock.unlock()
        let now = current(of: relative)
        let currentSource = now.source
        let hash = report.indexedContent[relative]
        let indexedSource = hash
            .flatMap { indexedContent(hash: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
        let indexed = indexedSource.map { $0.components(separatedBy: "\n") }
        let current = now.lines
        var map: [Int?]?
        if let indexed, let current { map = LineDiff.map(old: indexed, new: current) }
        let state = FileState(indexed: indexed, indexedSource: indexedSource, existedAtIndexing: hash != nil,
                              current: current, currentSource: currentSource, map: map)
        lock.lock()
        states[relative] = state
        lock.unlock()
        return state
    }

    /// The indexed text by its hash. The first file asked for fetches every changed file's text at
    /// once: one `git` process instead of one per file.
    private func indexedContent(hash: String) -> Data? {
        lock.lock()
        if let fetched { lock.unlock(); return fetched[hash] }
        lock.unlock()
        let all = IndexedText.contents(hashes: Array(report.indexedContent.values), projectRoot: root, home: home, git: git)
        lock.lock()
        fetched = all
        lock.unlock()
        return all[hash]
    }

    /// The symlink-resolved path, for a file that no longer exists too (`CanonicalPath.ofFile`).
    static func canonicalPath(_ path: String) -> String {
        CanonicalPath.ofFile(path)
    }

    /// `save(_:)` and `save:` are written `save` in source.
    static func baseName(_ name: String) -> String {
        String(name.prefix { $0 != "(" && $0 != ":" })
    }

    // MARK: - Identifier scans

    /// Positions (line, reported column) of identifier tokens spelled `name` in Swift
    /// source: comments and string literals are not tokens of that kind. With `declarationsOnly`,
    /// only the tokens that name a declaration.
    static func swiftIdentifiers(named name: String, in source: String, declarationsOnly: Bool) -> [(line: Int, column: Int)] {
        let tree = Parser.parse(source: source)
        let columns = SwiftColumns(tree: tree)
        var result: [(line: Int, column: Int)] = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let text) = token.tokenKind,
                  text == name || text == "`\(name)`" else { continue }
            if declarationsOnly && !namesDeclaration(token) { continue }
            result.append(columns.position(of: token.positionAfterSkippingLeadingTrivia))
        }
        return result
    }

    private static func namesDeclaration(_ token: TokenSyntax) -> Bool {
        guard let parent = token.parent else { return false }
        if let node = parent.as(FunctionDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(StructDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(ClassDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(EnumDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(ProtocolDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(ActorDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(TypeAliasDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(AssociatedTypeDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(MacroDeclSyntax.self) { return node.name.id == token.id }
        if let node = parent.as(EnumCaseElementSyntax.self) { return node.name.id == token.id }
        if parent.is(IdentifierPatternSyntax.self) { return true }
        return false
    }

    /// Positions of `name` as a whole identifier in C-family source, outside comments, string and
    /// character literals. Lexical: a macro, a selector piece or a member of another type with the
    /// same spelling matches as well.
    static func lexicalIdentifiers(named name: String, in source: String) -> [(line: Int, column: Int)] {
        let bytes = Array(source.utf8)
        let needle = Array(name.utf8)
        func isIdentifierByte(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: "_") || byte >= 0x80
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        }
        var result: [(line: Int, column: Int)] = []
        var index = 0, line = 1, lineStart = 0
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == UInt8(ascii: "\n") {
                line += 1
                lineStart = index + 1
                index += 1
            } else if byte == UInt8(ascii: "/") && next == UInt8(ascii: "/") {
                while index < bytes.count && bytes[index] != UInt8(ascii: "\n") { index += 1 }
            } else if byte == UInt8(ascii: "/") && next == UInt8(ascii: "*") {
                index += 2
                while index < bytes.count && !(bytes[index] == UInt8(ascii: "*") && index + 1 < bytes.count
                                               && bytes[index + 1] == UInt8(ascii: "/")) {
                    if bytes[index] == UInt8(ascii: "\n") { line += 1; lineStart = index + 1 }
                    index += 1
                }
                index += 2
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                index += 1
                while index < bytes.count && bytes[index] != byte && bytes[index] != UInt8(ascii: "\n") {
                    if bytes[index] == UInt8(ascii: "\\") { index += 1 }
                    index += 1
                }
                if index < bytes.count && bytes[index] == byte { index += 1 }
            } else if isIdentifierByte(byte) {
                let start = index
                while index < bytes.count && isIdentifierByte(bytes[index]) { index += 1 }
                if index - start == needle.count && Array(bytes[start..<index]) == needle,
                   !(byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) {
                    result.append((line, SourceColumn.column(after: bytes[lineStart..<start])))
                }
            } else {
                index += 1
            }
        }
        return result
    }
}
