// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sextant",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sextant", targets: ["sextant"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/indexstore-db.git", branch: "release/6.2"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        // Structural search beyond Swift. The grammars are C, compiled into the binary; the
        // Objective-C one is community-maintained, the rest come from the tree-sitter org.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter.git", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c.git", from: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp.git", from: "0.23.0"),
        .package(url: "https://github.com/amaanq/tree-sitter-objc.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "SextantCore",
            dependencies: [
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterObjc", package: "tree-sitter-objc")
            ]
        ),
        .executableTarget(
            name: "sextant",
            dependencies: ["SextantCore"]
        ),
        .testTarget(
            name: "SextantCoreTests",
            dependencies: ["SextantCore"]
        )
    ]
)
