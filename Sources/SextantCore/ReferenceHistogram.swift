/// A compact histogram of occurrences: grouped by file, with line numbers deduplicated and
/// sorted, and a deterministic file order. Complete — no occurrence is lost — but without
/// snippets, which saves the agent's tokens compared with a line-by-line list.
public enum ReferenceHistogram {
    public static func byFile(_ references: [SourceLocation], path: (SourceLocation) -> String) -> [(file: String, lines: [Int])] {
        let grouped = Dictionary(grouping: references, by: path)
        return grouped.keys.sorted().map { file in
            var seen = Set<Int>()
            let lines = grouped[file]!.map(\.line).filter { seen.insert($0).inserted }.sorted()
            return (file, lines)
        }
    }
}
