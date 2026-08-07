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

- `changed` diffs Objective-C, C and C++ at the symbol level, not just Swift. A past revision has
  no build of its own, but it does not need one: its text is parsed against the flags the file is
  compiled with today, which measures clean. A file with no flags at all, or a revision that does
  not parse, is named with the reason instead of being counted as unchanged.
- `lint` runs its rules over Objective-C, C and C++ as well, reading each file once for all of
  them. A rule written for another language simply does not compile there, which is not a gap; a
  file where **no** rule could run is reported, because nothing about it was checked.
- `api` reports the public surface of C++ headers. They used to come from the index, which lists a
  header's free functions and drops every class — a surface that looks complete and is not,
  because the index carries no access level. A header with any C++ in it is now read through
  clang, private and protected members excluded, using the flags of a translation unit that
  includes it; a header no compiled source includes is named rather than shown as empty. The MCP
  `api` tool answers the same as the CLI, which it did not before: it was never given the index,
  so through MCP the surface was Swift-only.
- `search` reads Objective-C, C and C++ through clang, so a structural pattern is no longer a
  Swift-only question: `sextant search '[$X reloadData]'` finds message sends the way
  `try? $X.save()` finds Swift calls. The pattern is compiled inside each file, appended to it in
  memory, because that is the only place its selectors are known — compiled on its own, an
  Objective-C pattern comes back from clang with an empty selector under ARC. Whatever cannot be
  read is named with its reason (no flags, the pattern does not compile here, a header is not a
  compilation unit), never counted as "no matches".
- Occurrences inside `#if` branches the build does not contain are reported too, as a separate,
  textual tier. clang runs the preprocessor, so such code never reaches the tree and cannot be
  matched structurally — on SDWebImage a search finds 15 usages where grep counts 28, the other
  13 sitting under `#if SD_UIKIT` on a macOS build. Reporting only 15 would leave an agent about
  to change that API to break another platform; merging them would pass a textual guess off as a
  verified match. So both are given, labelled and separate: `15 matches` plus `⚠ 13 more textual
  occurrence(s) inside #if branches not built for x86_64-apple-macosx10.13 — found by text, NOT
  structurally verified`. `--json` carries them in `inactiveOccurrences`.
- A compile database: `index` records the exact flags each Objective-C, C and C++ file was built
  with, and `doctor` reports whether every such source is covered. This is the groundwork for
  reading those files structurally ([ADR-0004](docs/adr/0004-structural-layer-for-c-family.md)):
  clang builds a complete AST only with per-file flags, and roughly a third of one with guessed
  flags — so the flags have to come from the build, and a file without them will be refused rather
  than answered for. They are read from the build graph SwiftPM writes (`.build/<configuration>.yaml`),
  where each clang node carries its arguments as a JSON array, rather than scraped from build
  output: an incremental build that compiles nothing prints nothing, while the graph still
  describes every file. An Xcode build writes no such graph and says so.
- Objective-C, C and C++ across the semantic commands. The index store is written by the whole
  clang family, so this needed symbol resolution to be fixed rather than a parser to be added:
  selectors (`greetWithName:`) are now matched, and a symbol declared in a header now resolves
  to its definition in the implementation file.
- `map` and `api` cover the same languages, reading Objective-C and C declarations from the
  index; C++ headers go through clang instead (see above), because the index carries no access
  level.
- `body` extracts C, C++ and Objective-C declarations. It previously answered for Swift only,
  and a C++ struct that happened to parse as Swift came back missing its trailing `;`.
- A four-language fixture (Swift, Objective-C, C, C++) with an Objective-C protocol and its
  conformers, and brace traps inside strings, character literals and comments.
- [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md): the structural layer for the
  C family will be built on libclang, not tree-sitter, with the measurements behind that.
- `golden` accepts `callees` assertions. The command shipped without regression cover in the
  spec that exists to provide it.
- Fixture cover for C++ overloads, an uninstantiated template, a nested namespace and an
  Objective-C category. All four already worked; overloads resolve to separate USRs, so callers
  of one signature are not attributed to the other.

### Changed

- **Breaking (`--json` schema):** `search --json` returns `{"matches": [...], "notScanned": [...]}`
  and `lint --json` returns `{"violations": [...], "notScanned": [...]}`, each in place of a bare
  array. Every `notScanned` entry is `{"file": ..., "reason": ...}` — a file left out, and why.
- `search` and `lint` name the non-Swift files they skipped, in the text output, in `--json` and
  in the MCP answer. Both commands walk `.swift` only, so on a project with Objective-C sources
  they used to report "No matches." and "✅ No violations found" about files they had not read —
  a clean bill of health covering unexamined code. The tool descriptions say so too, because an
  agent never sees stderr. Actually reading those files is [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md) work.
- **Breaking (`--json` schema):** `changed --json` returns an object
  `{"files": [...], "notDiffed": [...]}` instead of a bare array; the former array is now the
  `files` field. Each `notDiffed` entry is `{"file": ..., "reason": ...}`.
- `changed` names the C, C++ and Objective-C files it could not compare. It used to drop them, so
  a commit touching only `.m` files reported "no symbol-level changes" — a confident wrong
  answer of exactly the kind this tool exists to prevent.

### Fixed

- `construct` looked for the Swift shape `Type(` in every language, so on an Objective-C project
  it found nothing at all — which reads as "nothing constructs this type" rather than "this
  command cannot see it". Objective-C creates objects by sending `alloc` or `new` to the class,
  and that is what is looked for there now. A substring match also counted `makeStore(` as
  constructing `Store`; a shape now has to start at a word boundary.
- Index store selection used the store directory's own modification date, which does not change
  when units are rewritten inside it. A stale store could win over a fresh one and the semantic
  commands would answer from it — silently, and wrongly. All three selection sites now use the
  same freshness layer.
- `map` printed two messages about one missing index.
- `callees` counted call sites as callees: a method called twice on one line was reported as two.
  Results are now grouped per symbol, with the extra sites listed under it. `hierarchy` showed the
  same child twice for the same reason, and the duplicate also consumed its breadth budget.

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
