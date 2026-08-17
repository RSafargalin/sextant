# Formula for the project's own tap (RSafargalin/homebrew-tap, one tap for every tool).
# This file is the source of truth;
# it is copied into the tap repository as Formula/sextant.rb.
#
# Installs the prebuilt universal binary from a GitHub Release — no Swift toolchain needed.
# The version / url / sha256 fields are updated per release: .github/workflows/release.yml prints
# a ready-made block with the values filled in into the release notes.
class Sextant < Formula
  desc "Code intelligence for Swift: repo map, structural search, semantics"
  homepage "https://github.com/RSafargalin/sextant"
  # Updated per release from the block that release.yml prints into the GitHub Release notes.
  # No explicit `version`: Homebrew scans it from the URL, and a second copy would be one more
  # place to forget on release day.
  url "https://github.com/RSafargalin/sextant/releases/download/v0.9.0/sextant-0.9.0-macos-universal.tar.gz"
  sha256 "2486c4a998287c467f0970f9382819996d90df0b7d9aaf4423bfe59996246255"
  license "Apache-2.0"

  # The binary targets macOS 13+ (see platforms in Package.swift).
  depends_on macos: :ventura

  def install
    bin.install "sextant"
  end

  # An Xcode toolchain is deliberately not declared as a dependency: without one the tool is still
  # useful (the syntactic layer), so a hard depends_on xcode would block installation for nothing.
  def caveats
    <<~EOS
      The semantic layer (refs / defs / callers / impls / context / blast / hierarchy / body)
      needs an Xcode toolchain: libIndexStore.dylib is located via `xcrun --find swiftc`.
      Without one, the syntactic commands still work: map, api, search, lint, changed.

      Check the setup:
        sextant doctor --project <path>

      Build an index store for a project:
        sextant index --project <path>          # SPM
        sextant index --project <path> --app    # app target via xcodebuild

      Register it with Claude Code as an MCP server:
        claude mcp add sextant -- #{opt_bin}/sextant mcp --project <path>
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/sextant --version")
    assert_match "sextant", shell_output("#{bin}/sextant help")
  end
end
