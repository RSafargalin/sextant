import Foundation

/// A file's declarations behind a content-hash cache: on an unchanged file it skips SwiftSyntax parsing.
/// A shared layer for `map` and `api`. It survives sessions and worktrees, since the key is a content hash.
public enum DeclarationCache {
    public static func makeStore() -> PersistentCache<[Declaration]> {
        PersistentCache<[Declaration]>(namespace: "declarations-v3")
    }

    public static func declarations(
        for url: URL,
        parseCache: SourceParseCache,
        store: PersistentCache<[Declaration]>
    ) -> [Declaration]? {
        guard let hash = ContentHash.ofFile(url.path) else { return nil }
        if let cached = store.value(forKey: hash) { return cached }
        guard let tree = parseCache.tree(atPath: url.path) else { return nil }
        let declarations = SwiftDeclarationExtractor.declarations(tree: tree)
        store.set(declarations, forKey: hash)
        return declarations
    }
}
