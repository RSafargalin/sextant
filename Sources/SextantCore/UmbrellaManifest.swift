/// Generates a temporary umbrella Package.swift: a single manifest depending on all of the
/// project's packages, so they build in one pass and shared dependencies compile once.
public enum UmbrellaManifest {
    public struct PackageReference: Sendable, Equatable {
        public let path: String       // absolute path to the package directory
        public let identity: String   // identity (the last path component)
        public let products: [String] // names of the library products

        public init(path: String, identity: String, products: [String]) {
            self.path = path
            self.identity = identity
            self.products = products
        }
    }

    /// Escapes a string for safe insertion into a Swift literal in the manifest.
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Text of the umbrella manifest. The platform comes from the real packages, not a hardcoded value.
    public static func manifest(packages: [PackageReference], macOSVersion: String) -> String {
        let dependencies = packages
            .map { "        .package(path: \"\(escaped($0.path))\")" }
            .joined(separator: ",\n")
        let productDependencies = packages
            .flatMap { package in package.products.map { "            .product(name: \"\(escaped($0))\", package: \"\(escaped(package.identity))\")" } }
            .joined(separator: ",\n")

        return """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "SextantUmbrella",
            platforms: [.macOS("\(macOSVersion)")],
            dependencies: [
        \(dependencies)
            ],
            targets: [
                .target(
                    name: "SextantUmbrella",
                    dependencies: [
        \(productDependencies)
                    ]
                )
            ]
        )
        """
    }
}
