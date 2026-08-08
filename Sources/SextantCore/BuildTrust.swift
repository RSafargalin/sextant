import Foundation

/// What `index` executes, and what the platform does and does not protect while it runs.
///
/// Every other command in this tool reads. `index` is the one that runs the project's own code —
/// `Package.swift`, build plugins and macros are code, and a `Run Script` phase in an Xcode target
/// is a shell script. The tool is offered for use on foreign projects, and it is driven by agents
/// that read a tool description and act, so the exposure has to be stated where the decision is
/// made rather than buried in `help`.
///
/// Wrapping the build in `sandbox-exec` was measured and is **impossible**: SwiftPM applies its own
/// sandbox to the manifest, and a nested `sandbox_apply` is denied by the kernel — even a fully
/// permissive outer profile breaks the build. What that measurement also showed is that most of the
/// protection is already there, and it differs sharply between the two paths, which is exactly what
/// the notices below say.
public enum BuildTrust {
    /// Measured on macOS 26.5.2 / Swift 6.2.3 by running a hostile manifest and a hostile build
    /// plugin. Kept as data rather than prose so a test can assert the notices stay in step with it.
    public struct Protection: Sendable, Equatable {
        public let networkFromManifest: Bool
        public let writeToHome: Bool
        public let readHome: Bool
        public let writeToTemporary: Bool
    }

    /// What SwiftPM's own sandbox allows a manifest and a build plugin to do.
    public static let swiftPM = Protection(
        networkFromManifest: false, writeToHome: false, readHome: true, writeToTemporary: true
    )

    /// Printed before `swift build` runs. Three lines, because it prints on every index: what runs,
    /// what holds it back, and the way to avoid running anything at all.
    public static let swiftPackageNotice = """
        ℹ sextant index builds this project — Package.swift, its build plugins and its macros are code, and they will run.
          SwiftPM sandboxes the manifest and the plugins: no network and no writing into your home directory (measured),
          though they can read it. Compilation itself, macros included, is outside that measurement.
          Built it already? `sextant index --no-build` indexes an existing store and runs nothing.
        """

    /// Printed before `xcodebuild` runs. The difference from the SPM path is not a nuance: a
    /// `Run Script` build phase is an ordinary shell script with the full access of whoever
    /// started it, and no sandbox of ours or SwiftPM's is between it and the machine.
    public static let xcodeNotice = """
        ℹ sextant index --app runs xcodebuild — `Run Script` phases are shell scripts and execute with your full
          access, in no sandbox. Only for a project you would build by hand.
          Built it in Xcode already? `sextant index --no-build` indexes an existing store and runs nothing.
        """

    /// The one-line form for `help index` and for tool descriptions an agent reads before deciding.
    public static let summary =
        "index RUNS the project's build (Package.swift, plugins, macros; with --app also Run Script phases) — only on code you trust. `--no-build` runs nothing."
}
