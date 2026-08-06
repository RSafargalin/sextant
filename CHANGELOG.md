# Changelog

**English** | [Русский](CHANGELOG.ru.md)

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The stability contract covers **CLI flags, JSON output schemas, MCP tool names and their
input schemas, and exit codes**. Breaking any of those requires a major version bump.
Human-readable text output is not covered — parse `--json`, not prose.

## [Unreleased]

### Added

- Objective-C, C and C++ across the semantic commands. The index store is written by the whole
  clang family, so this needed symbol resolution to be fixed rather than a parser to be added:
  selectors (`greetWithName:`) are now matched, and a symbol declared in a header now resolves
  to its definition in the implementation file.
- `map` and `api` cover the same languages, reading non-Swift declarations from the index. `api`
  refuses C++-only headers and reports how many it skipped: the index carries no access level,
  so listing them would present private members as public API.
- `body` extracts C, C++ and Objective-C declarations. It previously answered for Swift only,
  and a C++ struct that happened to parse as Swift came back missing its trailing `;`.
- A four-language fixture (Swift, Objective-C, C, C++) with an Objective-C protocol and its
  conformers, and brace traps inside strings, character literals and comments.
- [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md): the structural layer for the
  C family will be built on libclang, not tree-sitter, with the measurements behind that.

### Changed

- **Breaking (`--json` schema):** `changed --json` returns an object
  `{"files": [...], "notDiffed": [...]}` instead of a bare array; the former array is now the
  `files` field. `notDiffed` lists changed files the symbol-level diff could not read.
- `changed` names the C, C++ and Objective-C files it did not compare. It used to drop them, so
  a commit touching only `.m` files reported "no symbol-level changes" — a confident wrong
  answer of exactly the kind this tool exists to prevent. Diffing them needs the source text of
  an arbitrary revision, which an index cannot supply; that is ADR-0004 work.

### Fixed

- Index store selection used the store directory's own modification date, which does not change
  when units are rewritten inside it. A stale store could win over a fresh one and the semantic
  commands would answer from it — silently, and wrongly. All three selection sites now use the
  same freshness layer.
- `map` printed two messages about one missing index.

## [0.7.0] — 2026-08-05

First public release.

### Added

- Repository documentation for public use: `README`, `CONTRIBUTING`, `SECURITY`,
  `CODE_OF_CONDUCT`, `AGENTS.md`, issue and pull request templates. Documents written for
  people ship in English and Russian (`*.ru.md`).
- `docs/benchmarks.md` — reproducible measurements on five public Swift packages at pinned
  commits, with the commands to re-run them.
- A regression test for index store selection across build configurations.

### Changed

- Renamed the project from its working title to **sextant**. This touches everything a user
  sees: the binary, the config file (`.sextant.json`), the rules file, the MCP server name,
  the URL scheme, the cache directory (`~/Library/Caches/sextant`) and the
  `SEXTANT_NO_DAEMON` environment variable. There is no migration path from the old names —
  the tool had no public release under them.
- CLI help, MCP tool descriptions, error messages and code comments are now in English.
- `sextant help` shows the build timestamp next to the version, so two builds of the same
  version are distinguishable in the field. `sextant --version` still prints the bare version
  string — it is machine-readable and checked by the release workflow.
- CI and the release workflow run on the `macos-26` runner and select the newest available
  Xcode, failing loudly if the toolchain is older than Swift 6.2.

### Fixed

- **`body` works across the C family.** It parsed every file with SwiftParser, which silently
  mis-handled anything that was not Swift: an Objective-C `@implementation` returned nothing at
  all, so did a C function, and a C++ struct happened to parse as Swift and came back missing its
  trailing `;`. Non-Swift declarations are now delimited instead of parsed — the index already
  gives the exact definition line, so only the end has to be found. Objective-C containers run to
  `@end`, prototypes stop at their semicolon, and braces inside strings, character literals and
  comments are skipped rather than counted.
- **`api` reports the public surface of Objective-C and C targets.** In SwiftPM a target's
  public headers live in `include/`, which is the module map's own answer to what the target
  exposes — so this is the layout's definition of public, not a guess. C++ headers are
  deliberately refused: they declare private members alongside public ones and the index carries
  no access level, so listing them would present private members as public API. `api` says how
  many it left out rather than returning a surface that looks complete.
- **`map` covers Objective-C, C and C++.** Non-Swift files are read from the compiler index
  rather than through a second parser, so the repository map shows the whole project instead of
  its Swift half. A declaration repeated in a header and its implementation is listed once;
  one that exists only in a header is kept, since that is the only place it appears. When such
  files exist but no index has been built, the map says how many it could not read instead of
  quietly omitting them. Swift is still parsed with SwiftSyntax — the index carries no
  visibility information, and the map filters on access level — so a pure-Swift project takes
  exactly the path it did before, with no index required.
- **Semantic commands now resolve Objective-C symbols.** The index store is written by the
  whole clang family, not just swiftc, so Objective-C, C and C++ declarations were always in
  it — but two defects kept them out of reach. Objective-C methods that take arguments are
  stored as selectors (`greetWithName:`), which matched neither an exact name nor Swift's
  `name(` shape, so a bare method name resolved to nothing. And a symbol whose canonical
  occurrence is a header declaration — the norm in Objective-C and C — reported no definition
  at all, because the definition in the `.m` or `.c` was only ever collected as a reference.
  Both are fixed, so `refs`, `defs`, `callers`, `context` and the rest work across a language
  boundary: a Swift call spelled `greet(withName:)` is found as a caller of the Objective-C
  selector it actually calls. C and C++ needed no change; they already worked.

- **Semantic queries went blind on projects that had ever been built in release
  configuration.** The index store was selected by the modification time of the store
  *directory*, but a build rewrites unit files *inside* the store without touching that
  directory. A one-off `swift build -c release` therefore left a small, stale release store
  looking permanently "newer" than the debug store that regular builds keep current. On a
  real project this meant a 110-unit store was chosen over a 2203-unit one: `defs` found only
  test-target symbols, `impls` returned nothing for a protocol with a conforming actor in the
  same file, and every query was labelled `⚠ STALE` immediately after a successful `index`.
  Store selection now uses the same units-based freshness signal as the rest of the tool, in
  all three places that select a store (SPM packages, umbrella build, Xcode DerivedData). A
  store with no units is no longer a candidate at all.
- **`sextant init` wrote a non-existent binary path into `.mcp.json`.** When sextant was
  launched through `PATH`, `argv[0]` is the bare name `sextant`, which was resolved relative
  to the current directory — producing `<project>/sextant`. The launch path now comes from
  the kernel, so the registration points at the real binary. The stable `bin/` symlink is
  still preserved rather than resolved, so `brew upgrade` does not break the registration.

## Earlier versions

Developed privately up to 0.6.x; see `docs/roadmap.md` for the iteration history and the
gates each one had to pass. Those versions were never published, so no compatibility is
claimed for them.
