/// PageRank over the file reference graph — used to rank the map by importance.
public enum PageRank {
    /// Edges `from → to`: the file referencing a symbol points at the file defining it.
    /// Returns a score per node; higher means more central, that is, more widely referenced.
    public static func scores(
        nodes: [String],
        edges: [(from: String, to: String)],
        damping: Double = 0.85,
        iterations: Int = 30
    ) -> [String: Double] {
        guard !nodes.isEmpty else { return [:] }
        let count = Double(nodes.count)
        let nodeSet = Set(nodes)

        var outLinks: [String: [String]] = [:]
        for edge in edges where nodeSet.contains(edge.from) && nodeSet.contains(edge.to) {
            outLinks[edge.from, default: []].append(edge.to)
        }

        var score = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 1.0 / count) })
        for _ in 0..<iterations {
            var next = Dictionary(uniqueKeysWithValues: nodes.map { ($0, (1 - damping) / count) })

            // Dangling nodes, with no outgoing edges, distribute their score evenly.
            let danglingSum = nodes.filter { outLinks[$0]?.isEmpty ?? true }.reduce(0.0) { $0 + (score[$1] ?? 0) }
            let danglingShare = damping * danglingSum / count
            for node in nodes { next[node]? += danglingShare }

            for (from, targets) in outLinks where !targets.isEmpty {
                let share = damping * (score[from] ?? 0) / Double(targets.count)
                for target in targets { next[target]? += share }
            }
            score = next
        }
        return score
    }
}
