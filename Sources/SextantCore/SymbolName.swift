import Foundation

/// How a symbol's name, as the index stores it, is written in source.
enum SymbolName {
    /// The accessor kinds Swift's index names accessors with: `getter:area` is the getter of `area`.
    static let accessorKinds: Set<String> = ["getter", "setter", "willSet", "didSet", "init", "_read", "_modify",
                                             "read", "modify", "unsafeAddress", "unsafeMutableAddress"]

    /// The part of a name a line can be checked against: `save(_:)` and `save:` are written `save`,
    /// and an accessor `getter:area` is written as its property, `area`.
    static func written(_ name: String) -> String {
        let base = accessorKind(of: name).map { String(name.dropFirst($0.count + 1)) } ?? name
        return String(base.prefix { $0 != "(" && $0 != ":" })
    }

    /// The kind of accessor a name names (`getter` for `getter:area`); nil for any other name — an
    /// Objective-C selector such as `didSet:` or `setValue:forKey:` included.
    static func accessorKind(of name: String) -> String? {
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let kind = String(name[..<colon])
        let rest = name[name.index(after: colon)...]
        guard accessorKinds.contains(kind), let first = rest.first, first != ":",
              !rest.prefix(while: { $0 != "(" }).contains(":") else { return nil }
        return kind
    }
}
