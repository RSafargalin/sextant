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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0")
    ],
    targets: [
        .target(
            name: "SextantCore",
            dependencies: [
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
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
