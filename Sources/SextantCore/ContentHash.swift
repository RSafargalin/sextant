import CryptoKit
import Foundation

/// Content hash — the cache invalidation key. Unlike mtime it is stable across worktrees and
/// checkouts: identical content gives an identical key, reusable across sessions and worktrees.
public enum ContentHash {
    public static func ofFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return hex(SHA256.hash(data: data))
    }

    public static func of(_ string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
