# sextant

[![CI](https://github.com/RSafargalin/sextant/actions/workflows/ci.yml/badge.svg)](https://github.com/RSafargalin/sextant/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/RSafargalin/sextant?sort=semver)](https://github.com/RSafargalin/sextant/releases/latest)
[![Licence](https://img.shields.io/badge/licence-Apache--2.0-blue)](LICENSE)
[![Swift](https://img.shields.io/badge/swift-6.2%2B-orange)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](#installation)

**English** | [Русский](README.ru.md)

Code intelligence for local Swift projects: a repository map, structural search (a grep
replacement) and semantics — where a symbol is defined, who uses it, what a package exposes.
The point is to give an LLM agent precise, on-demand access to code instead of grep: better
answers, fewer tokens.

Reusable by design — it works against the root of any project rather than being wired into one.

## What it looks like

One question, one answer — instead of a grep-and-read-five-files loop. Both runs below are
sextant against its own repository:

```console
$ sextant context ProjectConfig
[index: spm · 1 store(s) · fresh]
── ProjectConfig  [struct]
   def: Sources/SextantCore/ProjectConfig.swift:4  public struct ProjectConfig: Codable, Sendable {
   usages: 12
     • Sources/SextantCore/ProjectConfig.swift:31  return .loaded(try JSONDecoder().decode(ProjectConfig.self, from: data))
     • Sources/sextant/IndexCommands.swift:47  switch ProjectConfig.read(projectRoot: root) {
     • Sources/sextant/MCPServer.swift:63  switch ProjectConfig.read(projectRoot: project) {
     • Sources/sextant/main.swift:41  func loadConfig(_ arguments: [String]) -> ProjectConfig? {
     …
   bases and protocols: Sendable

$ sextant blast SourceLocation
── blast radius: SourceLocation [struct]
   a change would touch: 9 files · 37 usages · 0 calls
     Sources/SextantCore/BlastRadius.swift
     Sources/SextantCore/IndexStore.swift
     Sources/SextantCore/SymbolContext.swift
     …
```

Add `--json` to any of it and an agent gets the same answer as structured data. The same
queries are exposed to Claude Code as MCP tools — see [MCP](#mcp--connecting-to-claude-code).

## Languages

The semantic commands (`refs`, `defs`, `callers`, `context`, `blast`, `hierarchy`, …) read the
compiler's index store, which is written by the whole clang family. They therefore work across
**Swift, Objective-C, C and C++**, including across a language boundary: a Swift call spelled
`greet(withName:)` is found as a caller of the Objective-C selector `greetWithName:` it
actually calls.

The structural layer (`map`, `api`, `search`, `lint`, `changed`) parses with SwiftSyntax and is
**Swift-only**. So on a mixed project you get full semantics everywhere and structure for the
Swift half.

## What it saves

Measured on five public Swift packages (Alamofire, swift-argument-parser, swift-numerics,
swift-nio, swift-syntax) at pinned commits. Full numbers and the commands to re-run them
yourself are in [docs/benchmarks.md](docs/benchmarks.md):

| Task | Saving vs reading the sources |
|---|---|
| Learn a package's public surface | **79–91%** |
| Learn one type, including all its extensions | **83–95%** |
| Repeat a query on an unchanged tree | up to **112×** faster (content-hash cache) |

The unit is bytes of output, because bytes are exactly reproducible while a token count
depends on the tokenizer. The comparison holds for the task "understand the surface", not
"understand the implementation": `api` returns signatures and doc summaries, not bodies. For
bodies there is `body`.

## Status

Working CLI and MCP server, version 0.7.x. 21 commands:

| Command | What it does | Layer |
|---|---|---|
| `map` | repository map under a token budget; `--semantic` — types by usage; `--pagerank` — files by centrality | syntax / semantics |
| `api` | public surface of a package (attributes, doc summaries) | syntax |
| `search <pattern>` | structural search over the AST (`$X`, variadic `$$$`, statement patterns) | syntax |
| `lint` | structural hygiene rules (`--rules <json>`) | syntax |
| `refs` / `defs` / `callers` | usages / definition / call sites (callers account for protocol dispatch) | semantics |
| `callees` | what a symbol calls (best effort: calls within the project) | semantics |
| `impls` / `supertypes` | implementations and subtypes, bases and protocols of a type | semantics |
| `hierarchy <symbol>` | transitive call graph (`--callees` / `--callers`, `--depth N`) | semantics |
| `context <symbol>` | one-shot summary: definition, usages, callers, callees, hierarchy | semantics |
| `blast <symbol>` | impact analysis: what a change to this symbol touches | semantics |
| `body <symbol>` | full text of a declaration (signature and body) | semantics + syntax |
| `construct <type>` | construction and injection sites (heuristic: `Type(`) | heuristic |
| `changed` | symbol-level git diff: what was added, removed, or changed signature | syntax |
| `golden` / `bench` | semantic regressions against a spec / latency and output volume | measurability |
| `mcp` | MCP server (stdio) for Claude Code — the semantic layer as tools | integration |
| `init` | set up a project: `.sextant.json`, registration in `.mcp.json`, and a check | integration |
| `serve` | daemon with a warm index: cold CLI start 2.6s → 0.27s (measured on sextant itself) | integration |
| `doctor` | self-check of the setup (sources, libIndexStore, index store, freshness) | diagnostics |
| `index` | build an index store: SPM (`swift build`) or an app target (`--app`, xcodebuild) | build |

Common flags: `--json` (structured output), `--scope <subdirectory>`, `--max-files <N>`,
`--no-build`, `--reindex` (rebuild the index before the query). Defaults come from
`.sextant.json`. `.gitignore` is respected.

## Installation

Three routes; only the third needs a Swift toolchain.

**1. Homebrew (tap)** — recommended:

```bash
brew tap RSafargalin/tap
brew trust RSafargalin/tap
brew install sextant
sextant --version
```

Homebrew refuses to load formulae from an untrusted third-party tap, so `brew trust` is
required — it is a one-time acknowledgement that you are installing from someone's personal
tap rather than homebrew-core.

**2. Prebuilt binary from a release** — macOS universal (arm64 + x86_64), no Homebrew:

```bash
V=0.7.0
curl -fsSL -O "https://github.com/RSafargalin/sextant/releases/download/v$V/sextant-$V-macos-universal.tar.gz"
shasum -a 256 "sextant-$V-macos-universal.tar.gz"   # compare with the sha256 in the release notes
tar -xzf "sextant-$V-macos-universal.tar.gz"
xattr -d com.apple.quarantine sextant || true       # clear quarantine (absent attribute is not an error)
mkdir -p ~/.local/bin && install -m 0755 sextant ~/.local/bin/sextant
```

The binary is **neither signed nor notarised** (there is no developer certificate). Downloaded
through a browser, Gatekeeper attaches a quarantine attribute and blocks the first run; clear
it with `xattr -d com.apple.quarantine sextant`. Downloads via `curl` and Homebrew are not
quarantined, but the command is harmless either way.

**3. From source** — needs Swift 6.2+:

```bash
swift build && swift test
make ci                       # build + test + self-lint
make install                  # release binary into ~/.local/bin (add it to PATH)
swift run sextant help
swift run sextant map --project <path>
```

### What the semantic layer needs

The syntactic commands (`map`, `api`, `search`, `lint`, `changed`) run on a bare system. The
semantic ones (`refs`, `defs`, `callers`, `callees`, `impls`, `supertypes`, `hierarchy`,
`context`, `blast`, `body`) need an **Xcode toolchain**: `libIndexStore.dylib` is located
through `xcrun --find swiftc`, and the index store is produced by `swift build` or
`xcodebuild`. To check a setup, run `sextant doctor --project <path>` — a checklist with
actionable hints about whatever is missing.

## Daemon (faster CLI)

Every CLI invocation pays to open the index store — on a grown store that is around 2.6s, and
**every** sub-agent pays it. The daemon keeps the index open:

```bash
sextant serve --project /path/to/project &   # in the background, one per project
```

Clients use it automatically; with no daemon running they fall back to the normal path, which
is not an error. `SEXTANT_NO_DAEMON=1` disables the daemon entirely. Builds and setup
(`index`, `init`, `doctor`) are never executed by the daemon — they run foreign code and write
into the project.

Measured on sextant itself (53 MB store, identical state): `refs` **2.6s → 0.27s**, roughly
10×. On a small freshly built store the difference is smaller, because reusing the database
between runs already gets you to ~0.3s.

## MCP — connecting to Claude Code

`sextant mcp` is a stdio MCP server (JSON-RPC 2.0). The index is opened once at start-up and
reused, so a warm request costs ~0.2s against a cold shell-out. Freshness is handled by
`listenToUnitEvents` plus a poll before each request: an index built during the session is
picked up without restarting the server. 13 tools:

`context`, `blast_radius`, `body`, `who_defines`, `find_references`, `find_callers`,
`list_implementations`, `call_hierarchy`, `repo_map`, `structural_search`, `lint`,
`api` (the public surface of a package or type — an order of magnitude cheaper than reading
files) and `changed` (symbol-level git diff).

Tools honour `.sextant.json` (budget, scope, rules) exactly as the CLI does. The tool list in
`initialize` is generated from the contract, so it cannot drift from the actual set.

The easiest way in is one command at the project root. It creates `.sextant.json`, registers
the server in `.mcp.json` (any servers already there are preserved) and tells you what to do
next:

```bash
sextant init
```

Manually, through the client (after `make install` the binary is at `~/.local/bin/sextant`):

```bash
claude mcp add sextant -- ~/.local/bin/sextant mcp --project /path/to/project
```

Or with a `.mcp.json` at the project root:

```json
{
  "mcpServers": {
    "sextant": {
      "command": "/absolute/path/to/sextant",
      "args": ["mcp", "--project", "/path/to/project"]
    }
  }
}
```

The semantic tools need an index store, so build one first (`sextant index`, or
`index --app`). Without an index the server still starts, `repo_map` works, and the semantic
tools return a hint rather than a wrong answer.

Before registering, check the setup with `sextant doctor --project <path>` — a checklist
(sources, libIndexStore, index store and its freshness) with hints about what to build.

## Architecture

| Layer | Purpose | Technology | Status |
|---|---|---|---|
| L1 repo map | symbol map under a token budget | SwiftSyntax | ✅ |
| L2 structural | structural search and rules, a grep replacement | own engine (SwiftSyntax) | ✅ |
| L3 semantic | defs / refs / callers / public API | IndexStoreDB | ✅ |
| L3+ semantic | callees / type hierarchy / transitive call hierarchy / PageRank map | IndexStoreDB relations | ✅ |
| L4 MCP | commands as tools for an agent (stdio JSON-RPC, warm index) | MCP (stdio) | ✅ |
| L5 | other languages in the structural layer, dead code, real time | — | ⬜ non-goal for v1 |

**Non-goals for v1:** real-time file watching, vector search, a non-Swift structural layer. These are
deliberate cuts rather than oversights; several are scheduled for later iterations in
`docs/roadmap.md` (which, along with the architecture decision records, is in Russian — it is
a historical record of how the tool got here).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and expectations, and [AGENTS.md](AGENTS.md)
for the invariants that are not visible from the source.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE). The same licence as Swift and swift-syntax, which
this tool is built on.
