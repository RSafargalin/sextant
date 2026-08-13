import Foundation

/// Project config `.sextant.json` — command defaults, which CLI flags take precedence over.
public struct ProjectConfig: Codable, Sendable {
    public var budget: Int?
    public var maxFiles: Int?
    public var scope: String?
    public var rules: String?
    /// Files to leave out of every walk, as glob patterns relative to the project root.
    public var exclude: [String]?

    public init(budget: Int? = nil, maxFiles: Int? = nil, scope: String? = nil, rules: String? = nil,
                exclude: [String]? = nil) {
        self.budget = budget
        self.maxFiles = maxFiles
        self.scope = scope
        self.rules = rules
        self.exclude = exclude
    }

    /// Result of reading the config. It distinguishes "no file" (normal) from "a file that does
    /// not parse" — a user's typo, which is reported rather than silently ignored.
    public enum Outcome: Sendable {
        case missing
        case loaded(ProjectConfig)
        case invalid(String)
    }

    /// Reads `<projectRoot>/.sextant.json`.
    public static func read(projectRoot: String) -> Outcome {
        let url = URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(".sextant.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .invalid("file is not readable") }
        do {
            let config = try JSONDecoder().decode(ProjectConfig.self, from: data)
            // A misspelled key decodes cleanly and does nothing, so a whole configuration can be
            // inert while `doctor` reports the file as read. An unknown flag is a hard error here;
            // an unknown key was silence.
            let unknown = unknownKeys(in: data)
            guard unknown.isEmpty else {
                let known = Self.knownKeys.sorted().joined(separator: ", ")
                return .invalid("unknown key(s): \(unknown.sorted().joined(separator: ", ")) — known keys are \(known)")
            }
            return .loaded(config)
        } catch {
            return .invalid(describe(error))
        }
    }

    static let knownKeys: Set<String> = ["budget", "maxFiles", "scope", "rules", "exclude"]

    /// Top-level keys the config does not declare.
    static func unknownKeys(in data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(object.keys).subtracting(knownKeys)
    }

    /// A short reason instead of a DecodingError dump: the user needs where it broke, not the type.
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let context):
            let details = (context.underlyingError as NSError?)?.userInfo["NSDebugDescription"] as? String
            return details ?? context.debugDescription
        case .keyNotFound(let key, _):
            return "missing key '\(key.stringValue)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "«\(path)»: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    /// The project config; nil when the file is absent or did not parse.
    public static func load(projectRoot: String) -> ProjectConfig? {
        guard case .loaded(let config) = read(projectRoot: projectRoot) else { return nil }
        return config
    }

    /// Rules path resolved against the project root: the key belongs to the project, while the
    /// process working directory is chosen by the client (arbitrary for an MCP server), so a
    /// relative path would otherwise be looked up in the wrong place.
    public func rulesPath(projectRoot: String) -> String? {
        guard let rules, !rules.isEmpty else { return nil }
        guard !rules.hasPrefix("/") else { return rules }
        return URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(rules).path
    }
}
