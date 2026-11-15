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
        // Declarations of the libclang C ABI. The toolchain ships libclang.dylib but not the
        // clang-c headers, so the subset in use is declared here and the symbols are resolved at
        // run time — the binary keeps working on a machine without a toolchain, where the Swift
        // commands do not need clang at all.
        .target(name: "CClangShim"),
        // The same arrangement for libIndexStore: IndexStoreDB answers about symbols, this reads
        // the units themselves — which file each was compiled from, and for which build.
        .target(name: "CIndexStoreShim"),
        .target(
            name: "SextantCore",
            dependencies: [
                "CClangShim",
                "CIndexStoreShim",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "sextant",
            dependencies: ["SextantCore"]
        ),
        // Gives the test process a home of its own before any test runs, so no test reads or
        // writes the real `~/Library/Caches/sextant` or a client's configuration.
        .target(name: "TestHome", path: "Tests/TestHome"),
        .testTarget(
            name: "SextantCoreTests",
            dependencies: ["SextantCore", "TestHome"]
        )
    ]
)
