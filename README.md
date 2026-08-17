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
sextant against its own repository; the lists are trimmed where marked `…`, everything else is
verbatim:

```console
$ sextant context ProjectConfig
[index: spm · 1 store(s) · fresh]
── ProjectConfig  [struct]
   def: Sources/SextantCore/ProjectConfig.swift:4  public struct ProjectConfig: Codable, Sendable {
   usages: 12
     • Sources/SextantCore/ProjectConfig.swift:21  case loaded(ProjectConfig)
     • Sources/sextant/IndexCommands.swift:47  switch ProjectConfig.read(projectRoot: root) {
     • Sources/sextant/MCPServer.swift:63  switch ProjectConfig.read(projectRoot: project) {
     • Sources/sextant/main.swift:41  func loadConfig(_ arguments: [String]) -> ProjectConfig? {
     …
   bases and protocols: Sendable

$ sextant blast SourceLocation
[index: spm · 1 store(s) · fresh]
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

`map` and `api` cover the same four languages. `map` and the Objective-C and C parts of `api`
read declarations from the index rather than from a second parser, which is why they need a
built index. C++ headers go through clang instead: the index carries no access level, and a
surface that cannot tell a private member from a public one is not a public surface.

The structural commands — `search` and `lint` — parse source text, which an index does not hold.
Swift goes through its own parser; Objective-C, C and C++ go through clang, with the exact flags
each file was built with ([ADR-0004](docs/adr/0004-structural-layer-for-c-family.md)). Those
flags come from `sextant index`, so without a built index those files are not read — and are
named, rather than passed over in silence. `changed` reads the same four languages: a past revision's text is
parsed against the flags the file is built with today. `construct` is a heuristic and knows the
shape each language builds an object with.

### What it does not read: Interface Builder

`.storyboard` and `.xib` files are **not** read — not now and not later. A class, an outlet or an
action named only from a nib is invisible: `refs` and `blast` count the references written in
code, and a binding made in Interface Builder is not one of them.

Concretely, on the reference project: 56 storyboards, 270 xibs and 376 classes bound from them —
and **zero** classes that exist only there. So the cost is an undercount when weighing the impact
of a change, never a confident "nobody uses this" about a class a nib instantiates. Where a nib is
the only user, the tool will say a symbol has no references and be wrong about it; if that is your
layout, `grep` the nibs.

The reason is scope, not difficulty: in 2026 bare Interface Builder is a rare way to build an Apple
app, and reading it would mean a second parser, a second notion of a reference and a second thing
to keep honest ([ADR-0007](docs/adr/0007-no-interface-builder.md)).

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

Working CLI and MCP server, version 0.9.x. 27 commands:

| Command | What it does | Layer |
|---|---|---|
| `map` | repository map under a token budget; `--semantic` — types by usage; `--pagerank` — files by centrality | syntax / semantics |
| `api` | public surface of a package (attributes, doc summaries) | syntax |
| `search <pattern>` | structural search over the AST (`$X`, variadic `$$$`, statement patterns); Swift through its own parser, Objective-C/C/C++ through clang | syntax |
| `lint` | structural hygiene rules (`--rules <json>` replaces the built-in set; `{"extends": "builtin"}` adds to it), across the same languages as `search` | syntax |
| `refs` / `defs` / `callers` | usages / definition / call sites (callers account for protocol dispatch) | semantics |
| `callees` | what a symbol calls (best effort: calls within the project) | semantics |
| `impls` / `supertypes` | implementations and subtypes, bases and protocols of a type | semantics |
| `hierarchy <symbol>` | transitive call graph (`--callees` / `--callers`, `--depth N`) | semantics |
| `context <symbol>` | one-shot summary: definition, usages, callers, callees, hierarchy | semantics |
| `blast <symbol>` | impact analysis: what a change to this symbol touches | semantics |
| `body <symbol>` | full text of a declaration (signature and body) | semantics + syntax |
| `construct <type>` | construction and injection sites (heuristic: `Type(`, or `[Type alloc]` in Objective-C) | heuristic |
| `changed` | symbol-level git diff: what was added, removed, or changed signature; what it could not compare is named | syntax |
| `golden` / `bench` | semantic regressions against a spec / latency and output volume | measurability |
| `adoption` | how much code navigation went through sextant rather than grep, and what went past it | measurability |
| `hook` | records one tool-use event for a client hook (`--install` explains it) | measurability |
| `mcp` | MCP server (stdio) for Claude Code — the semantic layer as tools | integration |
| `init` | set up a project: `.sextant.json`, registration in `.mcp.json`, and a check | integration |
| `serve` | daemon with a warm index: cold CLI start 2.6s → 0.27s (measured on sextant itself) | integration |
| `store` | index stores in reach, and the policy that decides between them (`store use <policy>`) | diagnostics |
| `doctor` | self-check of the setup (sources, libIndexStore, index store, freshness) | diagnostics |
| `index` | build an index store and capture the C-family compile flags: SPM (`swift build`) or an app target (`--app`, xcodebuild) | build |

Shared flags, each on the commands it makes sense for: `--project <path>` (every command),
`--json` (structured output, on every command that answers a query), `--reindex` (rebuild the
index before the query), `--scope <subdirectory>` and `--max-files <N>` (`map`, `api`, `search`,
`lint`). Run `sextant <command> --help` for the exact set. Defaults come from `.sextant.json`.

### Big projects: a bounded answer, never a refusal

The four file-walking commands are minutes of work on a large project — measured on one with
12 351 files: `search` 335s, `api` 139s and 3.75 MB of output, `lint` over six minutes. So the walk
is bounded by `--max-files` (default 4000, from `.sextant.json` if set), and what it did not read
is named:

```
⚠ covered 4000 of 12351 file(s): the walk stops at --max-files 4000.
  The rest were not looked at — narrow with --scope <subdirectory>, or raise --max-files.
```

The bound is a prefix of the file list in a fixed order, so two runs cover the same files. It used
to be a refusal instead, which answered a question about the first four thousand files with
nothing at all.

`api` is separate: a public surface is a contract, so it is **not** cut by default however large it
is. `--budget <tokens>` bounds it when you want that, and the header then states what was left out
(`⚠ truncated: 1384 file(s) with 13778 declaration(s) left out by --budget 6000 tok`). Over MCP the
budget does have a default — an agent reads the answer into a context window.

### Which index store answers

A project routinely has more than one index store: `swift build` writes one, an editor's own
indexer writes another, a second checkout brings its own. They answer the same question
differently — measured on this repository, `refs SwiftSources` gives **83** usages in 22 files
from the store built last and **34** in 12 files from a store seven days older, while merging
both gives **91** — and nothing in the answer shows which was read.

So the tool does not choose. While one store is usable there is nothing to decide and nothing is
asked. As soon as a second one is usable, semantic commands refuse until a policy is set:

```
sextant store                 # what is in reach, what each policy gives, what it costs
sextant store use recency     # one store — the one built last
sextant store use union       # all of them, merged; freshness taken from the oldest
sextant store use coverage    # the one built from most of this project's files
```

Every answer carries what the opened store covers, next to its freshness — the two are different
questions and a fresh store can still hold half the project:

```
[index: derivedData · 1 store(s) · fresh · covers 10337/12351 files (84%)]
```

Measured on this repository, the same query against two stores of one project: `covers 92%` →
74 usages in 23 files, `covers 55%` (a release build, which compiles no test target) → 46 in 17.
The smaller number used to arrive with nothing to explain it.

`coverage` measures rather than guesses: it reads the units of each store and counts how many of
the files on disk it was actually built from. On this repository that is 132 of 143 files for the
store `swift build` wrote and 69 of 143 for the editor's own — which has *more* units. It costs a
full read of the units the first time (4.8s on a 22 725-unit store, ~0.5s cached against the
store's timestamp) and is measured only when there is more than one usable store.

The choice is written to `.sextant.json` (`storePolicy`). Override it for one command with
`--store-policy`, for one machine with `SEXTANT_STORE_POLICY`, or bypass it entirely with
`--index-store <path>`. Whenever there was a choice, every answer carries the line that says how
many candidates there were, which are being read, and why the others were not. See
[ADR-0006](docs/adr/0006-store-policy-is-a-persons-decision.md).

`.gitignore` is respected in full — under git directly, and outside it by handing the directory
to git as a work tree whose git dir lives in the cache, so nothing is written into the project. To leave
out files that *are* tracked on purpose — generated code, vendored sources, snapshot fixtures —
list globs under `exclude` in `.sextant.json`, or pass `--exclude` (repeatable, and it replaces
the config list rather than adding to it):

```json
{ "exclude": ["Generated/**", "Sources/*/Legacy", "*.pb.swift"] }
```

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
V=0.9.0
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

**3. From source** — needs Swift 6.2+. Note that `make install` puts the binary in
`~/.local/bin`, which usually comes before Homebrew's directory in `PATH`: from then on that
copy is what runs, and `brew upgrade` cannot replace it. `sextant doctor` says so when it finds
more than one.


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

Task-shaped examples — the question, the command, and its real output — are in
[docs/recipes.md](docs/recipes.md).

`sextant init --client <name>` registers the server for another client — `claude-code` (the
default, a file in the project) or `claude-desktop` (one list per machine). Only clients verified
against the running application are offered: a config written from documentation and never
launched fails silently, and the user blames the tool.

## Shell completion

```bash
sextant completion zsh > "${fpath[1]}/_sextant"     # then restart the shell
sextant completion bash > /usr/local/etc/bash_completion.d/sextant
```

The script is generated from the command catalog, so it always offers the commands and flags the
installed binary actually has — regenerate it after an upgrade.

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

### What `index` runs, and what holds it back

Every other command reads. `index` is the one that runs the project's own code: `Package.swift`,
build plugins and macros are code, and with `--app` a `Run Script` phase is a shell script. Run it
on code you would build by hand. If you have already built the project, `sextant index --no-build`
finds the existing store and runs nothing.

The two paths are protected differently, measured on macOS 26.5.2 / Swift 6.2.3 with a hostile
manifest and a hostile build plugin:

| | `index` (SwiftPM) | `index --app` (xcodebuild) |
|---|---|---|
| Writing into your home directory | denied by SwiftPM | **allowed** |
| Network from the manifest or plugin | denied by SwiftPM | **allowed** |
| Reading your home directory | **allowed** | **allowed** |

SwiftPM sandboxes the manifest and the plugins, so foreign code can read your home directory but
cannot write to it or send what it read anywhere — a leak needs a second stage. Compilation itself,
macros included, runs under `swiftc` rather than SwiftPM and is outside that measurement. The
`--app` path has no sandbox at all: a `Run Script` phase runs with your full access.

Wrapping the build in `sandbox-exec` is not possible: SwiftPM applies its own sandbox, and a nested
one is denied by the kernel — even a fully permissive outer profile breaks the build.


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
[docs/roadmap.md](docs/roadmap.md). The architecture decision records under `docs/adr/` are in
Russian — they are a historical record of how the tool got here.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and expectations, and [AGENTS.md](AGENTS.md)
for the invariants that are not visible from the source.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE). The same licence as Swift and swift-syntax, which
this tool is built on.
