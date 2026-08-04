/// Comparison of version strings such as "26.0" or "26.1.2".
public enum SemanticVersion {
    /// Returns `lhs >= rhs` component by component; missing components count as zero.
    public static func atLeast(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue { return leftValue > rightValue }
        }
        return true
    }
}
