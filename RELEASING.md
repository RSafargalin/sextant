# Releasing sextant

**English** | [Русский](RELEASING.ru.md)

A release is: a version bump, a tag, an automated build of a universal macOS binary, and a
formula update in the tap. Most of it is automated; the manual parts are listed here because
they are easy to forget between releases.

## Before you start

- The version lives in **four kinds of places**. The release workflow enforces the first one
  and will refuse a mismatched tag, but nothing checks the rest:

  ```bash
  grep -rn "0\.[0-9]*\.[0-9]*\|0\.[0-9]*\.x" \
    Sources/SextantCore/Sextant.swift README.md README.ru.md docs/benchmarks.md docs/benchmarks.ru.md
  ```

- `main` must be green in CI. The release workflow runs the tests again, but discovering a
  failure after tagging means burning a tag.

## 1. Prepare the version

Pick the number. Before 1.0, a change that breaks CLI flags, JSON schemas, MCP tool names or
exit codes is a **minor** bump; everything else is a patch. Those four are the stability
contract — see [CHANGELOG.md](CHANGELOG.md).

1. Bump `Sextant.version` in `Sources/SextantCore/Sextant.swift`.
2. In both changelogs, rename `## [Unreleased]` to `## [X.Y.Z] — YYYY-MM-DD` and add a fresh
   empty `## [Unreleased]` above it.
3. Update the version references found by the `grep` above: the "version 0.N.x" line in both
   READMEs, `V=…` in the download snippet, and the environment line in both benchmark pages.
   If the benchmarks were not re-measured, only the version string changes — the numbers are
   a record of what was measured and stay as they are.
4. Run the full local check:

   ```bash
   make ci
   ```

5. Commit and push. **Wait for CI to go green before tagging.**

## 2. Tag

```bash
git tag v0.7.0 && git push origin v0.7.0
```

The tag must match `Sextant.version` exactly, without the `v`. The release workflow compares
them and fails loudly if they differ — that check exists so a release cannot lie about its own
version in `sextant --version` and in the MCP handshake.

## 3. What the workflow does

[`.github/workflows/release.yml`](.github/workflows/release.yml) then, without further input:

- selects the newest Xcode and refuses to continue on a toolchain older than Swift 6.2;
- runs the tests again (a tag can be placed on a commit that never went through a PR);
- builds arm64 and x86_64 in separate passes and joins them with `lipo`, asserting that the
  result really carries both architectures;
- checks that the binary reports the expected version and that `sextant help` runs;
- packages the archive, computes its sha256, and publishes a GitHub Release containing the
  archive, the checksum file, and installation instructions;
- prints a ready-made `version` / `url` / `sha256` block for the formula into the release
  notes.

If it fails halfway, fix the cause and re-run the workflow on the same tag: publishing is
idempotent — a repeat run re-uploads the artefacts instead of failing.

## 4. Update the formula

`Formula/sextant.rb` in this repository is the source of truth; the tap holds a copy.

1. Copy the three values from the release notes into `Formula/sextant.rb`, replacing the
   placeholders (`version "0.0.0"`, the `v0.0.0` URL, the all-zero `sha256`).
2. Commit that change here.
3. Copy the file into the tap repository — **[RSafargalin/homebrew-tap](https://github.com/RSafargalin/homebrew-tap)**,
   one tap shared by all the tools — as `Formula/sextant.rb`, and push.

The tap repository must keep the `homebrew-` prefix: `brew tap RSafargalin/tap` is a shortcut
for `https://github.com/RSafargalin/homebrew-tap`, and that expansion is what makes the short
form work.

## 5. Verify the published result

On a machine that has never had this version:

```bash
brew update && brew install RSafargalin/tap/sextant
sextant --version   # must print exactly the released version
sextant help        # the build timestamp confirms which binary is running
```

An upgrade from a previous version:

```bash
brew update && brew upgrade sextant
```

The strongest check is a machine **without** an Xcode toolchain: the syntactic commands
(`map`, `api`, `search`, `lint`, `changed`) must work there, and the semantic ones must fail
with an actionable message rather than a wrong answer. `sextant doctor --project <path>`
should list exactly what is missing.

## Notes

**The binary is not signed or notarised.** There is no developer certificate. Downloaded
through a browser it gets a quarantine attribute; both the release notes and the README say
how to clear it. Homebrew and `curl` downloads are unaffected.

**Pre-releases.** A version containing a hyphen (`0.8.0-rc1`) is published as a GitHub
pre-release automatically — the workflow derives that from the tag, nothing extra to do.

**After the release**, keep `## [Unreleased]` in both changelogs populated as work lands.
Writing it at release time is how entries get lost.
