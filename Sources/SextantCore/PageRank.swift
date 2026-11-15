/// PageRank over the file reference graph — used to rank the map by importance.
public enum PageRank {
    /// Edges `from → to`: the file referencing a symbol points at the file defining it.
    /// Returns a score per node; higher means more central, that is, more widely referenced.
    ///
    /// The same graph gives the same scores to the last bit, whatever order the nodes and edges
    /// come in: the nodes are processed in sorted order and every sum is taken in that order, so no
    /// hash-table iteration order (which differs between runs) reaches the arithmetic.
    public static func scores(
        nodes: [String],
        edges: [(from: String, to: String)],
        damping: Double = 0.85,
        iterations: Int = 30
    ) -> [String: Double] {
        let ordered = Array(Set(nodes)).sorted()
        guard !ordered.isEmpty else { return [:] }
        let count = Double(ordered.count)
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })

        var outLinks = [[Int]](repeating: [], count: ordered.count)
        for edge in edges {
            guard let from = position[edge.from], let to = position[edge.to] else { continue }
            outLinks[from].append(to)
        }
        for index in outLinks.indices { outLinks[index].sort() }

        var score = [Double](repeating: 1.0 / count, count: ordered.count)
        for _ in 0..<iterations {
            var next = [Double](repeating: (1 - damping) / count, count: ordered.count)

            // Dangling nodes, with no outgoing edges, distribute their score evenly.
            var danglingSum = 0.0
            for index in ordered.indices where outLinks[index].isEmpty { danglingSum += score[index] }
            let danglingShare = damping * danglingSum / count
            for index in ordered.indices { next[index] += danglingShare }

            for from in ordered.indices where !outLinks[from].isEmpty {
                let share = damping * score[from] / Double(outLinks[from].count)
                for target in outLinks[from] { next[target] += share }
            }
            score = next
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, score[$0.offset]) })
    }

    /// Items ordered by score, highest first; equal scores in the order of `name`, so the ranking
    /// is the same on every run.
    public static func ranked<Item>(_ items: [Item], scores: [String: Double], name: (Item) -> String) -> [Item] {
        items.sorted { lhs, rhs in
            let left = scores[name(lhs)] ?? 0, right = scores[name(rhs)] ?? 0
            return left != right ? left > right : name(lhs) < name(rhs)
        }
    }
}
