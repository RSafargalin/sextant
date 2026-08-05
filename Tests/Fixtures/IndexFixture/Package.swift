// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IndexFixture",
    products: [.library(name: "IndexFixture", targets: ["IndexFixture"])],
    targets: [
        // Objective-C target: the semantic layer must resolve across the language boundary,
        // and Objective-C names are stored as selectors rather than in Swift's spelling.
        .target(name: "ObjCFixture"),
        .target(
            name: "IndexFixture",
            dependencies: ["ObjCFixture"],
            // The language mode is pinned so the fixture compiles identically on every
            // toolchain. Left implicit, strictness follows whichever Swift the machine has,
            // and CI fails on a compiler stricter than the developer's.
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
