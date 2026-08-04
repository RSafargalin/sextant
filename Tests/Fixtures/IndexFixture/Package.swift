// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IndexFixture",
    products: [.library(name: "IndexFixture", targets: ["IndexFixture"])],
    targets: [
        .target(
            name: "IndexFixture",
            // The language mode is pinned so the fixture compiles identically on every
            // toolchain. Left implicit, strictness follows whichever Swift the machine has,
            // and CI fails on a compiler stricter than the developer's.
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
