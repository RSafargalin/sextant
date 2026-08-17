# Roadmap — sextant

**English** | [Русский](roadmap.ru.md)

The path is built in iterations of increasing value: take the main technical risk off the table
cheaply first, then grow. Every iteration is useful on its own and closes with a **gate** —
without confirmed value we do not move on.

- **Updated:** 2026-07-22
- **Decision:** option B (a reusable tool, a separate product).
- **Maturity strategy:** `docs/adr/0001-evolution-to-production-maturity.md` — the directions of
  growth towards production level (reliability, optimisation, radically new layers, memory zone).
- **MCP surface:** `docs/adr/0002-mcp-surface.md` — which MCP primitives Claude Code supports and
  which will survive the stateless transition (what we lean on, what we ignore).
- **Path to v1.0:** `docs/adr/0003-path-to-production-v1.md` — the order and the gates for closing
  the gap to production maturity (from the 2026-07-22 review); sprints P1–P5 come BEFORE Iter 8–10.

The architecture decision records are in Russian, and they label the directions Н1–Н6 and the
sprints П1–П5; this document writes them N1–N6 and P1–P5.

## North star

```
sextant (Swift package: CLI + MCP server)
  L1 repo-map   — symbol map under a token budget       (SwiftSyntax/tree-sitter)
  L2 structural — a grep replacement, structural search (ast-grep)
  L3 semantic   — defs/refs/callers/callees/public-API  (IndexStoreDB + sourcekit-lsp)
  L4 MCP        — tools + resources for Claude Code     (stdio, .mcp.json)
  L5 (done)     — multi-language (ADR-0004); freshness is a side effect of a build
```

## Iterations

### Iter 0 — Spike (throwaway). Take the main risk off the table. ✅ PASSED (2026-06-28)
Prove on project A: headless reading of an index store through IndexStoreDB gives accurate
find-references; settle a deterministic `-index-store-path` (drop the dependency on
`DerivedData/<Project>-*` hashes).
- **Gate:** `refs <symbol>` is accurate and reproducible. **Result — done:**
  `sextant spike --symbol Record` → struct `s:7AppCore6RecordV`, def `Record.swift:6:15`,
  **211** usages; `AggregatedRecordRepository` → 2 usages, cross-module.
  Checked against the sources (L3): definitions, kind and columns all match; no false positives.
  Auto-discovery of `libIndexStore.dylib` (via `xcrun`) and of a fresh DataStore — no config.
- **Shipped:** `IndexStore`, `DerivedDataLocator`, `SourceLocation`/`SymbolHit` (they stay as the
  seed of layer L3); the `spike` CLI command (to be replaced by `refs`/`defs` in Iter 2).
- **Deferred to Iter 1/2:** a *deterministic index store of our own* via
  `swift build --enable-index-store -index-store-path` (the spike reads the DerivedData store from
  the last Xcode build — that proves the query, not the freshness pipeline).

### Iter 1 — CLI MVP: map + structural search. Cross-project, shippable. ✅ PASSED (2026-06-28)
`sextant map --project <path>` (a token-budget map) and `sextant search <pattern>` (ast-grep).
Cheap, low risk, useful immediately.
- **Gate:** run it on project A **and** on a second project; "where do I start" is answered without
  grep. **Result — done:**
  - `map` on project A (several packages + an app target, a couple of hundred files) → a full map;
    the head of the map shows the entry points straight away (`LiveAppDependencies`, `AppMain`,
    `ContentView`) — without grep.
  - `map` on `sextant` itself (a second root) → full mode, cross-project use confirmed.
  - The token budget degrades: full → compact → truncation with a count of what was omitted.
  - `search` implemented as an ast-grep wrapper with graceful degradation (a hint if it is absent).
- **Shipped:** `SwiftDeclarationExtractor` (SwiftSyntax, build-independent), `RepoMap`
  (walk + grouping by package + rendering under a budget), `Declaration`/`FileSummary`; the
  `map` and `search` commands. Tests on the extractor (9 tests green in total).
- **Polish for later (does not block the gate):** ignore globs (today `docs/templates/*.swift`
  land in the map as a `docs` group); PageRank ranking by references (today navigation is by
  package/file and the budget cuts by traversal order); excluding `Package.swift` from the map.
- **ast-grep:** a live `search` needs `brew install ast-grep` (not installed yet).

### Iter 1.5 — Our own structural engine (option B). ✅ PASSED (2026-06-28)
Replacing the external ast-grep with a native engine on SwiftSyntax. Metavariables through
sentinel substitution (`$X` → a valid identifier, which at match time is a binding wildcard).
- **Shipped:** `PatternSearch` (pattern compilation + structural matching over the AST, ignoring
  trivia), `StructuralMatch`, a shared `SwiftSources` walk. The `search` command moved onto the
  engine; the ast-grep dependency removed.
- **Gate:** `sextant search '$X.current'` on project A → 13 matches, **exactly as grep (13=13)**,
  but structurally (the shape `expr.current`, not text). 13 tests green.
- **Supported:** single `$X` (expression position), consistency of repeated names.

### Iter 1.6 — Variadics + a hygiene rule engine. ✅ PASSED (2026-06-28)
Growing the engine to variadics and to an exact AST replacement for regex hygiene checks.
- **Shipped:** variadic `$$$` / `$$$Name` (absorbs any number of list elements, prefix+suffix),
  `Rule`/`RuleViolation`, `RuleEngine` (built-in rules + loading from JSON via `--rules`), the
  `lint` command.
- **Gate (L3, checked against grep):** `lint` on project A → dozens of violations: `system-state`
  13 (`.current`), `force-try` 39 (= grep `try!` 39), `print-call` 0. Exact, with no false
  positives. 17 tests green.
- **Value:** `sextant lint` = a reusable AST hygiene checker, more precise than a regex script;
  rules are configured per project by a JSON file.
- **Deferred:** statement patterns (`guard … else`), named variadics with binding,
  rewrite/codemod.

### Iter 2.1 — Semantic commands. The differentiator. ✅ PASSED (2026-06-28)
`refs`/`defs`/`callers` (IndexStoreDB) + `api` (syntactic, build-independent). Version 0.2.0.
- **Shipped:** `SymbolQuery` (definitions/references/callers by index roles), the
  `refs`/`defs`/`callers` commands (the spike turned into a product), `PublicAPI` + the `api`
  command. A filter for non-system symbols (otherwise `Record` collides with SwiftUI). Signature
  cleanup in `api`.
- **Gate (L3):** `defs Record` → AppCore/Models/Record.swift:6:15; `refs Record` → 211;
  `api --package AppFeature` → the public surface. 19 tests green.
- **Known caveats:** `callers` for a specific USR does not catch calls through a protocol or
  dynamic dispatch (those land on the protocol requirement); overloads are split by USR.
  `callees` deferred.
- **Deferred to Iter 2.2:** a deterministic store of our own via `swift build
  --enable-index-store` (today DerivedData from the last Xcode build is read — there is a
  freshness lag).

### Iter 2.2 — A deterministic index store. ✅ PASSED (2026-06-28)
Our own store, produced by a build, with no dependency on Xcode. Version 0.2.1.
- **Finding:** `swift build` has NO `--index-store-path`; `--enable-index-store` puts the store in
  `.build/<triple>/debug/index/store` (deterministic, one store per package).
- **Shipped:** the `index` command (`swift build --enable-index-store` across every SPM package:
  the root + `Packages/*`), `IndexStoreLocator` (finding packages and stores), `IndexStoreSet`
  (merging N stores with dedup by USR and position — for multi-package projects). Store
  resolution: `--index-store` → the project's SPM stores → DerivedData (fallback).
- **Gate (L3):** on sextant itself — `index` built a store in `.build/.../index/store`;
  `refs RepoMap` → def `RepoMap.swift:5:13` + 2 usages, from the SPM store (NOT Xcode).
  21 tests green. (The union works on project A with `index --project <root of A>` — several
  packages.)

### Iter 2.5 — Hardening (from a state review). ✅ PASSED (2026-06-28)
Preparing for MCP: latency, caching, tests, de-risking scale. Version 0.2.2.
- **`SourceParseCache`** (Core) — an AST cache keyed by mtime; threaded through map/api/search/lint.
  Within one invocation a file is parsed once; in a long-lived process (MCP) it keeps the AST warm
  between requests.
- **`lint` fix** — parse each file once for all patterns: **38.7s → 18.4s** (the remainder is
  matching 5 patterns in separate walks; a single multi-pattern walk would finish the job —
  deferred).
- **A stable index database path** — reuse between runs: `refs Record` **2.1s cold → 0.22s warm**
  (10×; critical for MCP).
- **Tests** on `IndexStoreSet.merge` (union/dedup), `RepoMap` (budget/degradation), the cache.
  26 tests.
- **De-risking on project A (a real run over all packages, 6 min):** `index` built the stores;
  found and fixed a **double count in the union** of stores with different roots (DerivedData from
  a different checkout than SPM) — resolution went back to "SPM if present, otherwise DerivedData"
  (a single root → clean dedup); `refs Record` 416→214.
- **The union does NOT produce duplicates (L3, version 0.2.3):** all 214 `Record` references are
  unique (`uniq -d` empty), one root. The earlier estimate of "~5% duplicates" was a MISTAKEN
  comparison (214 SPM packages vs 202 DerivedData — different scopes, not duplicates). "The
  definition twice" was an artefact of `defs` output (it printed the def header plus the same
  occurrence), fixed. Added the `--full-paths` and `--limit` flags.
- **Known limitations:** (1) the SPM index covers packages, NOT an xcodeproj app target (the app
  goes through DerivedData / separate app indexing, planned); (2) `lint` over a whole project is
  ~18s (an agent lints narrowly).

### Iter 2.6 — Acquisition robustness (generalisation). In progress.
From an audit on project B: index resolution was overfitted to project A.
- **2.6a ✅ PASSED (2026-06-29, v0.2.5):** DerivedData resolution by the `info.plist` WorkspacePath
  ⊂ project (not by scheme name), preferring an app workspace (`.xcodeproj`/`.xcworkspace`) over a
  nested package's `Package.swift`. The name-based `discoverDataStore` and the hard-coded project
  name removed (M3). Gate (L3): `refs AuthManager --project <root of B>` resolves automatically
  (previously "not found"); project A with no regression. 38 tests. Fixes the old 416 on the way
  (it cuts off a foreign worktree).
- **2.6b ✅ PASSED (v0.2.6):** an umbrella `index` — one pass instead of N, shared dependencies
  compiled once. Platforms and products from the manifests (`swift package dump-package`), not
  hard-coded. Single package → a direct build; multi → the umbrella; the store lives in the cache
  (`~/Library/Caches/sextant`). Gate (L3): project A 360s→113s, one store, refs Record=202.
  iOS-only packages → a clear error.
- **2.6c ✅ PASSED (v0.2.7):** scope control. `--scope <subdirectory>` narrows the area;
  `--max-files <N>` (default 4000) with an early exit. Gate (L3): project B `map` with no scope →
  guarded in 1.74s (it does not hang on a tree of hundreds of thousands of files);
  `--scope AppTarget/SomeFolder` → works; project A untouched.
- **G1 ✅ checked:** there is no staleness in a warm database in the CLI (it re-imports on every
  open). For MCP, `listenToUnitEvents: true` / reopening is needed (a requirement of Iter 3).

### Pre-MCP sprint — every non-MCP promise closed (v0.5.6, done)
Seven items of "properly and reliably, no compromises" before MCP:
1. **Transitive call hierarchy** (`hierarchy --callees/--callers --depth N`) — recursion over
   IndexStoreDB relations, cycle detection, a tree plus `--json`.
2. **`callers` through protocol dispatch** — accounting for the `.overrideOf` relation. A major fix
   came with it: **method resolution** (names in the index carry argument labels,
   `parse(_:referenceDate:)`) — before that refs/defs/callers/callees silently did not work for
   functions (types were hiding the bug).
3. **PageRank repo map** (`map --pagerank`) — a reference graph from the index → file centrality.
4. **`--reindex`** — rebuilding the index before a query (freshness at build granularity).
5. **App target** (`index --app`) — xcodebuild + `COMPILER_INDEX_STORE_ENABLE`, scheme
   auto-detection; covers app-target symbols that are absent from the SPM index
   (L3: `refs LiveAppDependencies`).
6. **Distribution** (`make install`) — a release binary into `~/.local/bin`.
7. **Integration tests for the core** — a miniature package fixture: build → index →
   defs/impls/refs against a real IndexStoreDB (closes audit finding P0). 50 tests, `make ci`
   green.

### Iter 3 — The MCP wrapper. Integration with Claude Code. (v0.5.11, ✅)
Shipped: `sextant mcp` — a stdio MCP server (JSON-RPC 2.0, spec 2025-06-18), a sequential loop
(one client → no concurrency hazards), a warmed `IndexStoreSet` at start-up. **9 tools:**
`context` (the headline — a summary of a symbol in one call instead of a series of greps),
`who_defines`, `find_references`, `find_callers`, `list_implementations`, `call_hierarchy`,
`repo_map`, `structural_search` (an AST pattern — a grep replacement), `lint`. The contract lives
in Core (`MCPTools`), with a test.
**Live freshness:** `listenToUnitEvents`=true + `pollForUnitChangesAndWait` before every call →
it picks up a reindex without a restart. L3: initialize/tools-list/tools-call/ping/notification/
error paths all checked. Registration: `claude mcp add` / `.mcp.json` (README).
A **bare-name edge case** (parse/validate) was closed alongside: resolveOccurrences short-circuited
on `canonicalOccurrences(ofName:)` — one irrelevant exact symbol hid the methods; the fix is to
always search by prefix with a `== name || name(` filter.
- **Gate (outstanding):** in a live session the agent reaches for MCP instead of grep; measure the
  drop in grep usage.
- **Next, by appetite:** a `repo_map` resource with a subscription; PageRank weights/functions;
  multi-project (Iter 4).

### Field sprint (2026-07, v0.6.0) — work from a field report ✅

Input: a field report from an agent session (~79% token saving on Swift navigation).
Closed: **P0 MCP did not pick up a freshly built index** (store reopened by signature + poll);
**P2 `repo_map` ignored the budget**; **P2 `api --type`/`--scope`** (in the CLI); `body` (the body
of a declaration — closes the "defs does not reveal the body" fallback); `changed` (a symbol-level
git diff), `construct`, `doctor --fix`, hints on a miss, opt-in telemetry.
P1 (closures/static methods) — a spike found it was not a resolver bug; softened with a textual
fallback.

### Review 2026-07-22 — a full review of the tool, 4 major fixes ✅

Four independent lenses (architecture, correctness, UX/flexibility, tests). Four major bugs of
"silent wrongness" fixed: `changed` under a `--project` subdirectory (paths from the repo root,
`-z` for non-ASCII names); `api` lost `public extension` members and `public protocol`
requirements (access inheritance + a declarations-v2 cache bump); MCP served stale snippets (a
fresh `SourceLineReader` per message); `defs`/`body` passed a reference off as a definition (the
fallback no longer fills in `definition`). 79 tests green. The debt this exposed, and the order in
which to pay it down, are recorded in **ADR-0003** (sprints P1–P5).

## Forward plan (Iter 4+) — towards production maturity

Source: the 2026-06-29 brainstorm, `docs/adr/0001-evolution-to-production-maturity.md`
(directions) and `docs/adr/0002-mcp-surface.md` (what to lean on in MCP). Ordered by
leverage/cost: **measurability and trust first, then efficiency, surface, memory, and the
strategic layer.** The dependencies are explicit: memory (Iter 8) rests on content hashing
(Iter 5) and Resources (Iter 7). The numbers in brackets are items from the consolidated backlog
(48 entries).

**Status 2026-08-07:** Iter 4–5 are shipped, Iter 6–7 partially (see the notes below); what is
left of Iter 6–7, and the order of everything after it, are sprints P1–P5 in **ADR-0003**;
Iter 8–10 come after those.

Two items have since moved out of Iter 10, because they were built rather than deferred:

- **Multi-language (#36) is done** — [ADR-0004](adr/0004-structural-layer-for-c-family.md) closed
  with all four gates. `search`, `lint`, `changed`, `api` and `construct` read Objective-C, C and
  C++ through clang, on the flags captured from the build (SwiftPM's build graph, or the
  `xcodebuild` log for an Xcode project). Verified on SDWebImage from both build systems: the same
  15 structural matches plus 13 textual ones inside `#if` branches the build does not contain.
- **The adoption metric (#41) is done** — as its own `adoption` command plus a `hook`, not inside
  `bench`. What remains is not code but elapsed time: the number is worth reading only after real
  sessions with the MCP server registered. The hook was connected on 2026-08-17 — before that it was
  released but present in no `settings.json`, so the clock starts at that date, not at the release.

What that leaves open, in order: a fix to the navigation classifier, without which the adoption share
is biased in our favour (see "Lessons from someone else's tracker"); tuning the tool descriptions
(#39) and hinting away from grep (#40) — both wait on data, and the data waits on that fix; prompts
as slash commands (#30) and elicitation (#31); the second half of the P3 gate (`brew install` on a
machine with no Xcode toolchain); the three daemon questions (see Iter 6).

### Iter 4 — Measurability and trust. The foundation. ✅ SHIPPED (v0.6.0)
You cannot optimise what you do not measure, and you cannot call a tool "better" while it is
silently wrong.
- **`sextant bench`** — a fixed set of queries → p50/p95 latency, peak RSS, an **output token
  counter**; catches performance regressions in CI (#14).
- **A golden set** — `symbol → expected refs/def` on two real projects in CI, catching silent
  semantic regressions (#4).
- **Provenance in answers** — a marker for fresh / stale / syntactic fallback (#1).
- **Loud stale degradation** — never silently serve something plausible but incomplete (#2).
- **Cross-checking** semantics against the structural layer — a divergence is a flag (#3).
- **Semantic correctness:** bare-name protocol requirements (#47), multi-store dedup (#48).
- **Gate:** golden green on two projects; stale is never served unmarked; bench runs in CI.
- **Fact:** bench, golden (a deterministic tier on a fixture in CI plus a `--spec` CLI mode),
  provenance, loud degradation and cross-checking are all shipped. What is left of the gate:
  bench regressions in real CI (GitHub Actions — the operational maturity of ADR-0003).

### Iter 5 — Core efficiency (content hashing). The biggest machine win. ✅ SHIPPED (v0.6.0)
One architectural move (content hashing) covers speed, incrementality and cross-worktree
correctness at once.
- **A `git ls-files` walk** instead of FileManager (C speed, full gitignore); **it also fixes
  cross-worktree duplicates in refs** (#7, #46).
- **A parse cache keyed by content hash** (not mtime — that is fragile under
  checkout/worktree/stash); `map`/`lint`/`search`: O(all files) → O(changed files), persistent
  between runs (#8).
- **An in-memory `name→[USR]`** index — repeat lookups in O(1) (#6).
- **Gate:** a repeat `lint`/`map` on an unchanged tree is sub-second; the cross-worktree duplicates
  on project B are gone (verified); bench shows the speed-up.
- **Fact:** the git ls-files walk (#7), content-hash caches for map/api/lint/search (#8) and
  cross-worktree correctness (#46) are shipped. **#6 was not done** (the in-memory `name→[USR]`) —
  it moved into the daemon (N4/P4 of ADR-0003), where it belongs naturally.

### Iter 6 — Daemon + token efficiency. Speed, and a metric for what it costs. ⚠ PARTIAL
- **`sextant serve`** + a unix socket — a warm index for every CLI call (cold 2.1s→0.2s) (#5).
- **Adaptive verbosity** — compact for MCP, readable for a TTY, by isatty (#11).
- **A histogram instead of a list** — "55 usages: 3 extensions, 12 call sites, 40 annotations"
  (#12).
- **Line dedup + a deterministic order** (→ the model's prompt cache) (#13).
- **Gate:** bench records the drop in output tokens on typical queries; cold CLI start is gone.
- **Fact:** the token half is done — isatty verbosity (#11), the histogram (#12), dedup (#13).
  **`sextant serve` (#5) is done** — P4 of ADR-0003 is closed together with its prerequisite (actor
  isolation of the caches). Three questions remain, each checked in the code: the MCP server holds
  its own `IndexStoreSet` and never goes through the daemon (`runViaDaemon` is called only from
  `main.swift`), the parse cache is created per invocation (`MCPServer.swift`), and the daemon has
  no SIGINT/SIGTERM handler — killed by a signal, it leaves its socket file behind.

### Iter 7 — MCP surface + adoption. On the re-checked basis of ADR-0002. ⚠ PARTIAL
Only the primitives Claude Code supports and that survive the stateless transition.
- **`CLAUDE_PROJECT_DIR`** — clean project resolution instead of cwd/`--project` (#32).
- **Resources + templates + completion** — `repo_map`, a symbol's context and a feature map as
  resources reachable by `@`-mention; `list_changed` for the moving parts (#29, #33).
- **Prompts as slash commands** with no required arguments: `/feature_map`, `/impact` (#30).
- **Elicitation** behind an abstraction (ready for a future SEP-2322): "the index is stale —
  rebuild?", disambiguation (#31).
- **Tool annotations `readOnlyHint`** plus a simple `outputSchema`; a long build is NOT an inline
  tool (#34, #35).
- **Adoption mechanics:** tuning the tool descriptions (#39), intercepting or hinting away from grep
  (#40), an adoption metric (#41) — shipped as its own `adoption` command rather than inside
  `bench`, because bench measures latency on a fixed set of queries while adoption is a property
  of a session; the two answer different questions and share nothing; **`sextant init`** in one command (#37);
  prebuilt/Homebrew (#38).
- **Gate:** resources are reachable through `@`; the adoption metric (the share of searches that go
  through sextant) grows; staleness is handled interactively rather than by refusal.
- **Fact:** `CLAUDE_PROJECT_DIR` (#32), Resources + templates + completion (#29, #33),
  `readOnlyHint` (#34), `sextant init` (#37), prebuilt/Homebrew (#38 — shipped in 0.9.0, with the
  formula in `RSafargalin/homebrew-tap`), the adoption metric (#41) and CLI↔MCP parity (P1: an `api`
  tool, one shared config, per-tool-call telemetry) are done. **Outstanding:** prompts as slash
  commands (#30) — `prompts/list` currently returns an empty list, so it is a stub; elicitation
  (#31); description tuning (#39) and hinting away from grep (#40) — both wait on adoption data, and
  the data waits on a fix to the classifier (see "Lessons from someone else's tracker").

### Iter 8 — The memory zone (code-anchored). A context-offloading layer.
Rests on content hashing (Iter 5) and Resources (Iter 7). Automatic invalidation by anchor is what
separates it from dangerous generic memory.
- **An mmapped "project digest"** (a symbol table + the graph) — a query-optimised substrate (#10).
- **Memory by pointer** — `ctx://symbol@hash` handles instead of blobs, through resource links
  (#23).
- **A cache of derived knowledge** — the call graph, blast radius, a feature map, keyed by content
  hash (#24).
- **Rehydration after a context compaction** — an exact replacement for lossy compression (#26).
- **Architecture** — anchoring, hot/warm/cold tiering, LRU+relevance eviction, `derived` vs
  `asserted` provenance, worktree isolation (#28).
- **Phase 2 (the risk of `asserted`):** a session scratchpad (#25), a cross-session knowledge base
  (#27).
- **Gate:** on a long session, a measured drop in tokens thanks to handles/deltas; not one stale
  entry served unmarked.

> **Phase 1 is closed — measured, and there is no ceiling to win (2026-08-08).** Across 26 real
> agent sessions (~6.1 MB of navigational content) three independent definitions of "a repeat"
> agree: the same call with the same arguments is **0.9 %** of navigational bytes, a byte-identical
> result inside one session **0.5 %**, in a later session **0.5 %**, and a file re-read whose
> content had not changed **5.5 % of read bytes**. A dedup protocol can therefore reclaim single
> digits of a fraction of session tokens — before subtracting the handles' own cost (~15–20 tokens
> per answer). The reason is in the same numbers: an agent rarely asks twice, and when it re-reads
> a file the file has usually just been changed by the agent itself, which is exactly what a handle
> cannot serve. The spend is not in the repeat but in the **first** delivery — which is the context
> compiler (#16, Iter 10), untouched by this measurement. Reasoning and table in
> [ADR-0003](adr/0003-path-to-production-v1.md).
>
> **A second argument, independent of tokens (2026-08-17).** In Serena, cross-project memory
> poisoning is filed as a vulnerability alongside path traversal in memory paths
> ([#1251](https://github.com/oraios/serena/issues/1251)). Phase 2 ("the asserted risk") therefore
> buys not only a doubtful benefit but a class of attack: a note written in one project is read by
> another.

### Iter 9 — Differential context + automatic freshness.

> **Freshness is out of this iteration — the frame was disproved by measurement (P5 of
> ADR-0003, 2026-07).** An ordinary `swift build` **already** updates the index store, so a
> build hook would have solved a problem the environment had solved from the start. The real
> defect was in the freshness *signal*, and it is fixed: `IndexFreshness` in Core, one source
> for the whole tool. The `changed` command is the first step towards differential context
> (#15); there is no session-aware layer yet.
- **Differential context** (session-aware) — "unchanged since turn N" / deltas (#15).
- **Speculative prefetch** — warming the neighbours in the graph (#21).
- **The context budget as a protocol** — the agent declares a budget and sextant packs to fit (#45).
- ~~**Build-hook freshness** (#17)~~ and ~~**partial freshness by unit timestamps** (#9)~~ —
  **not doing.** See the reasoning and the measurement in
  [ADR-0003](adr/0003-path-to-production-v1.md); reopen only if re-importing units after a rebuild
  (~2.6s, masked by the daemon) is measured to actually get in the way.
- **Gate:** a repeat query returns a delta, not a dump; the index is fresh with no manual reindex.

### Iter 10 — The strategic layer (by appetite). A change of league.
- **A context compiler / retrieval inversion** — input = a task, output = a minimal context pack
  (#16).
- ~~**Multi-language** (#36)~~ — **done, 2026-08-07.** Semantics came through the index; the
  structural layer went through libclang rather than tree-sitter, and the reasoning, the
  measurements that overturned three of its own assumptions, and the four gates are in
  [ADR-0004](adr/0004-structural-layer-for-c-family.md).
- **Graph-RAG intent search** — embeddings grounded on the graph (the model is our own Anthropic
  API, NOT sampling) (#18).
- **A verification service** for claims (#19); **refactoring as a service** (#20).

  > **The documentation half of #19 was measured and has no defect to catch (2026-08-08).**
  > Agents read Markdown constantly — 18.5 % of file reads and 27 % of read bytes across 30 real
  > sessions, present in every one of 14 projects — and the files are README, roadmaps, ADRs and
  > plans. That made "check what the docs claim against the code" look obvious. It is not: broken
  > links and stale `file:line` references were counted across all 57 commits of this repository
  > (**0**) and across 221 documents in Alamofire, swift-nio, swift-syntax, swift-argument-parser
  > and swift-composable-architecture (**1**, itself probably a DocC asset reference). Documented
  > flags matched the command catalogue exactly, and the bilingual twins diverged nowhere once
  > `X.md` ↔ `X.ru.md` was normalised. A detector cannot be given a gate on a defect that does not
  > occur.
  >
  > The drift that **is** real here is semantic: this roadmap promised build-hook freshness as an
  > Iter 9 priority for weeks after ADR-0003 had recorded "not doing". Catching that means reading
  > two documents for contradiction — a model, which is a separate decision (#18 sets the terms:
  > our own API call, never sampling), not a Markdown parser.
  >
  > Still open and **not** measured: whether section-level navigation of docs (a table of contents
  > under a budget, fetch one section rather than a 5.6 KB file) saves anything. That is a claim
  > about the first delivery, and the same rule applies — measure before building.
- **Cross-project intelligence** — one index across every project (#22).
- **An architectural boundary linter** (#42); **"negative space"** for safe deletion plus dead code
  (#43); **online relevance learning** (#44).
- **Gate:** every feature gets its own measurement of value against a baseline before it is kept.

## Lessons from someone else's tracker — Serena (2026-08-17)

[Serena](https://github.com/oraios/serena) is the closest analogue by purpose: an MCP toolkit for
navigating and editing code, 40+ languages through LSP, 28k stars. The whole tracker was read: 823
issues, 762 closed and 61 open. This is not competitive analysis but a source of detectors —
someone else's bug is cheaper than your own.

**Breadth is a liability, not an advantage.** 332 of the 823 issues (40 %) are per-language and LSP
plumbing, and among the open ones that share is two thirds. Kotlin and Clojure leave zombie
processes, the Kotlin LS litters `/tmp`, Bloop survives `stop()` and gets reparented to PID 1, the
JDT LS fails to start on a newer Java, the Erlang LS has been archived, F# regressed. Every language
is an external process with its own lifecycle, permanently. Specialising on the Apple environment
declines that rent rather than narrowing the market. The second largest bucket is configuration and
installation: 213 issues. Separately,
[#1327](https://github.com/oraios/serena/issues/1327): their own language support tiers are
acknowledged as unreliable, so "Swift in the standard tier" promises nothing.

**Theses confirmed.** Their incidents are exactly what our honesty layer is built against:

- [#1814](https://github.com/oraios/serena/issues/1814): `find_referencing_symbols` returned `{}`
  because tsserver died of OOM — with `isError: false` and a log line saying "cross-file indexing
  complete". The reporter's phrasing for that failure shape: fast, confident and wrong; an agent will
  conclude that dead code is safe to delete.
  [#1593](https://github.com/oraios/serena/issues/1593) is the same class: `find_symbol` returning
  stale information.
- [#576](https://github.com/oraios/serena/issues/576),
  [#326](https://github.com/oraios/serena/issues/326),
  [#1744](https://github.com/oraios/serena/issues/1744): symbolic editing duplicates code, produces
  a syntax error, and silently skips files that are not open, leaving stale references behind. That
  answers the question "should we add editing": in a mature LSP-backed tool, the edit is silently
  wrong. If we ever do it, only behind a gate that the build is green afterwards.
- [#1325](https://github.com/oraios/serena/issues/1325),
  [#1042](https://github.com/oraios/serena/issues/1042): JSON output is consumed worse by a model
  than structured text. Our text surface with provenance inside the answer is not a lag.
- [#992](https://github.com/oraios/serena/issues/992),
  [#1607](https://github.com/oraios/serena/issues/1607): they arrived at content-hash validation
  after the pain; for us it was Iter 5, as an architectural move. And
  [#726](https://github.com/oraios/serena/issues/726), "preserve the exact source text", is free for
  us because we read files rather than only LSP nodes.
- Command injection through `shell=True`
  ([#1585](https://github.com/oraios/serena/issues/1585)): we do not have that class by construction
  — every child process is `executableURL` plus an argument array, never a shell.

**A defect this found in us.** [#1845](https://github.com/oraios/serena/issues/1845): Claude Code
2.1.117+ on native macOS/Linux builds removed the `Grep` and `Glob` tools and routes them through
`Bash` as the embedded `ugrep`/`bfs`. Our `NavigationAct` knew `grep, rg, ag, ack, ripgrep` and did
not know `ugrep` or `bfs`: of three events (`ugrep`, `bfs`, `rg`) fed to the installed binary, one
was recorded. Fixed on 2026-08-17 — one list for both paths (the hook and the transcript reader),
with a test over the whole list.

> **What that measurement did NOT show, and was claimed anyway.** It was first stated that our share
> is inflated. Checking did not bear that out: this project's transcripts contain no invocation of
> `ugrep` or `bfs` by name, and a `grep` typed on the command line already resolves to ugrep on this
> machine — the word in the command text stays `grep`, which the classifier always counted. So the
> hole in the classifier was real (L4, on synthetic events) while the data loss here was not. The
> fix stands as a guard against documented client behaviour (L2), not as a repair of a measured
> skew.

**Detectors we do not have** — each from someone else's mistake:

- the daemon is killed by a signal → no socket file is left and the next client does not trip over it
  ([#1464](https://github.com/oraios/serena/issues/1464),
  [#1816](https://github.com/oraios/serena/issues/1816));
- one unreadable, huge or oddly named file does not bring the walk down
  ([#514](https://github.com/oraios/serena/issues/514) — a crash on `.ico`,
  [#182](https://github.com/oraios/serena/issues/182) — a file name too long);
- the semantic layer dies mid-query → the answer is not empty without saying so (#1814).

**Taken from their data.** [#1491](https://github.com/oraios/serena/issues/1491) — a measurement over
21,089 tool calls, 192 sessions and 21 days: Serena is used in only 35.4 % of sessions, and its share
is 20.3 % of read-class operations. The second signal matters more: **18.4 % of symbol queries end in
a plain `Read` of the same file**, and in 80.8 % of those the symbol body was already in the answer
while the `Read` used `offset`/`limit` — the agent has the body and is reaching for the *surrounding*
lines. Two tasks follow: `--context-lines N` on `body` and `context`; and a fallback metric in
`adoption` — "after which of our answers did the agent go and read the file anyway". Their script
cannot do the second; our command can, because it reads whole transcripts.

**A quiet wrongness of our own, found on the way.** The MCP server echoes back whatever protocol
revision the client claims (defaulting to `2025-06-18`), which confirms support for something it may
not implement.

## Next up — done on 2026-08-17

Five fixes, not bets. All five are in `main` with CI green (330 tests).

1. **`ugrep` and `bfs` in the classifier** — one list of search tools for both paths instead of two
   copies drifting apart in silence; the test iterates the whole list, so a new name cannot be added
   without one.
2. **Three detectors** (`SurvivalTests`): a daemon killed by SIGINT or SIGTERM leaves no socket —
   there was no handler at all before; an unreadable, huge or oddly named file does not bring the
   walk down; a store with no records is named as broken. The third found a real defect: the
   degradation was loud, but **the reason given was false** — "does not resolve semantically (a
   closure, a local…)" about a store whose records had been deleted, which was meanwhile reported as
   `fresh`. Such a store is now recognised and named.
3. **`--context-lines N` on `body`** and **a fallback metric in `adoption`**. The flag went to `body`
   only, not to `context` as promised: in the #1491 data the follow-up is about the surroundings of
   the **declaration** (in 80.8 % of cases the body was already in the answer), while the same ±N
   lines around every reference would multiply the largest answer by (2N+1) on an unverified hunch.
   The metric counts how many of our answers were followed **next** by opening a file, and says
   plainly that this is adjacency rather than the same file: a transcript records calls, not answers.
4. **An honest MCP revision** — the server answers with its own (`MCPProtocol.revision`) rather than
   the client's, and logs the difference. A client naming a revision published after this build used
   to be told it was supported.
5. **`doctor` checks the chain** — the MCP registration and the hook: whether the binary named exists
   and whether the hook has ever written. Exactly the class that left the hook unnoticed for ten
   days. The logic lives in `ClientWiring`, with the settings-file list as a parameter, or the test
   would depend on the machine it runs on.

## Candidates after 0.9.0 — by axis, not by number

Not an iteration but a set of bets with different costs and risks. The order inside an axis is by
benefit over cost; the order between axes is decided by adoption data, once it is unbiased.

**Axis 1. Answers an LSP-based tool cannot give at all.** This is differentiation rather than
catching up: Swift 6 concurrency (`@MainActor` boundary crossings, `Sendable` gaps, actor isolation);
dead public surface (`api` ∩ `refs` — what is `public` but unused outside its module, a direct tool
for extracting one); references outside the static graph (`#selector`, `NSSelectorFromString`, KVO
strings: the index knows the `@objc` name, so a string can be tied to a symbol); the SwiftUI
injection graph (`@Environment`/`@EnvironmentObject` — a symbol reachable only through the
environment); `@available` and the deployment target (what is freed or broken by raising the minimum
iOS); a symbol's test coverage (which public symbols no test target mentions).

Four more answers belong here, each assembled from parts we already have:

- **`api --from <ref> --to <ref>` — a diff of the public surface with a semver verdict.** `changed`
  can compare revisions but reports every symbol rather than the contract; `api` cannot compare at
  all. For a library author, "what am I breaking with this release" is the question before a
  release. LSP has no notion of "a module's contract between two revisions".
- **`review <range>` — the impact of a whole PR rather than one symbol:** how many symbols are
  touched, the combined blast, how many of them are public, which have no tests, which targets are
  affected. A composition of `changed` + `blast` + `api` + target boundaries — and exactly the
  artefact a human reviewer wants. This is axis 4 in concrete form, without the product-frame
  conversation.
- **An import graph and cycles between targets** — the architectural check that feeds module
  extraction.
- **Owners inside the blast radius** — `git blame` over the use sites: "these two people should see
  this change". `git` is already at hand; `blame` is used nowhere.

**Axis 2. The reality of Xcode — the only real moat.** A workspace of several projects, several
schemes and configurations at once, the target as a first-class notion ("which targets does this
change break"). None of these notions exist in LSP. The prerequisite is a spike: run Serena on the
reference Xcode project and compare the answers. Without it, "we are stronger on `.xcodeproj`" stays
at L1.

**Axis 3. Distribution and trust in the install.** A one-step Claude Code plugin — the MCP server,
the hook and the slash commands in a single install (this closes #30 and removes three manual steps;
Serena has a heavily upvoted request for exactly this,
[#802](https://github.com/oraios/serena/issues/802)). An HTTP transport: today it is stdio only, so
cloud and remote sessions cannot reach sextant at all. `make verify-public` — the bench of five public
repositories plus `tea` as a repeatable artefact rather than one-off scripts: in the last run half the
false findings were bugs in the harness itself.

**Axis 4. A gate in someone else's CI — the only bet that goes around rather than against.** `lint`,
dead public surface, forbidden imports and module boundaries as a PR check. Half the infrastructure
exists: `golden` (semantic regressions against a spec) and `bench`. It makes the tool useful to a
team rather than only to an agent — and that is a conversation about the product frame, not an
evening's task.

**Axis 5. Optimisation — by measurement, not by feel.**

- **Warming the daemon on a build event.** Re-importing after a rebuild costs ~2.6s, and it is
  "masked by the daemon" only when the daemon is already alive *and* the query arrives afterwards.
  The daemon could watch the store and re-import ahead of time, so freshness comes free rather than
  at the expense of the first query.
- **An in-memory `name→[USR]` index (#6)** — the one unstarted item of Iter 5. It was moved into the
  daemon and forgotten there; the daemon now exists.
- **A verdict instead of a dump.** The last line of an impact answer should be a conclusion, not a
  list: "12 sites in 2 targets, 1 test covers it, the public contract does not change". Cheaper than
  the context compiler (#16) and aimed at the same spend — the first delivery, which the measurement
  named as the real one.

**Axis 6. Detectors for our own mistakes.** We add a detector for every defect that escaped; these
are the classes that still have none:

- **Property tests for reference counting.** There have been at least four counting bugs: double
  counting through macro expansion, `#if` branches, a position not carrying the name, and an
  internal cap presented as the total. It is our worst class, and it is guarded only by pointed
  tests. What it needs are invariants over randomly generated sources: the number of positions
  equals the number of references, no position falls outside the file, dedup is idempotent.
- **A load test for the daemon** — twenty concurrent clients. We have just fixed thread-pool
  starvation; the class is live and the test is missing.
- **Golden on a real repository**, not only on a fixture: a spec over one of the public projects
  catches silent semantic regressions on live code, which a fixture cannot.
- **Name ambiguity** — what we do when a name belongs to several USRs, and how an agent picks
  stably. No handling was found in the report (L1, needs a read of the code).

**Axis 7. Small honesty and process.**

- **Every refusal names the next command** — in places this is already true ("build the index:
  `sextant index`"), but not as a rule with a test behind it.
- **`--explain`** — the decision trail: which store, why, what coverage, what was left out.
  Provenance is one line today; the full trail serves both trust and debugging.
- **Byte-stable output on a repeat** — dedup and deterministic order (#13) were built for the
  model's prompt cache, but nothing locks in that they stay that way.
- **The ledger mechanism in AGENTS.md** — `withKnownIssue` (green while the defect lives, failing
  the moment it is fixed) closed 24 defects and is documented nowhere as the standard practice.
- **`adoption` closes the loop on #39** — it can propose which tool description to change, based on
  the shapes of the queries that went past us.

## Backlog — waiting on circumstances, not on work

Nothing here is blocked on a decision or on someone writing code. Each item needs something to
happen in the world first, so it stays here instead of being raised at every planning turn.

- **The second half of the П3 gate: `brew install` on a machine with no Xcode toolchain.** The
  first half (a machine with one) is done. This half needs a machine that does not exist yet in
  reach; without it, the claim "installs without a toolchain" stays at L1.
- **Adoption data.** `sextant adoption` reads transcripts and works. The `PreToolUse` hook was
  written and released but **never connected**: it sat in no `settings.json` for ten days, and the
  snippet `hook --install` printed named a binary that does not exist (built from `argv[0]`, which
  is the bare name under `PATH`), so pasting it would have installed a hook that silently records
  nothing. Both are fixed as of 2026-08-17 — the snippet resolves the running binary, and the hook
  is registered at user level, verified by a record appearing in the log. The clock therefore starts
  now: the signal only means anything after roughly a week of ordinary sessions, and until then #39
  (tool descriptions) and #40 (intercepting grep) have no ground to stand on, because both are
  changes aimed at a behaviour that has not been measured yet.
- **Linux.** Never planned either way. The semantic layer is IndexStoreDB (portable), the Swift
  structural layer is SwiftSyntax (portable), the C-family layer is libclang loaded by `dlopen`
  (portable in principle, but the path search is written for Xcode). The open question is not
  "how hard" but "for whom" — no one has asked for it.

## Closed by measurement, not by opinion

### A shared IndexStoreDB directory across processes — harm NOT confirmed (2026-08-17)

The database directory is derived from the store path, so every process working on one store shares
one database. That was recorded as a defect ("two processes silently re-import it"). Measured, it is
the opposite: sharing is what makes concurrency cheap.

Stand: the reference project's Xcode store, 22 725 units, 528 MB; `refs AbsAccountsViewModel`;
`SEXTANT_NO_DAEMON=1`; times are per process, wall clock.

| processes | one shared database | one database per process |
|---:|---:|---:|
| 1 | 25.0s | 29.5s |
| 2 | 25.2s | 44.6s (36.2–53.0) |
| 4 | 34.4s | 73.8s |

The control matters more than the numbers: per-process databases were built by copying the store to
four paths, so each process had its own key. They are **worse at every level** — four separate
256 MB databases thrash the page cache while one shared mapping is read by all four.

What was checked besides speed: every run returned the same answer (`usages: 7 in 3 file(s)`) at
1, 2 and 4 processes, on a cold database and on a warm one; a query after the whole run still
answered correctly; the database stayed 2 files and 256 MB. Nothing indicated a re-import, a lock
that never released, or corruption.

One case does cost: a CLI query importing a cold database while a daemon holds the same store open
took 36.5s against 24.7s for the same cold import alone. It happens once after a rebuild, the
answer was correct, and attributing it to the shared database rather than to two processes working
at once would need a further control that has not been run.

Not tested: more than four processes, a store being rewritten by Xcode *during* the queries, and
any platform other than this one. The item is closed as unconfirmed rather than fixed — there is
nothing to fix until one of those shows harm.

## Canonical queries (the system's acceptance test)

Each of these must be answerable without a text grep:
1. "who calls `X`"
2. "where is type `Y` defined"
3. "the public API of package `Z`"
4. "every implementation of protocol `P`"
5. "a map of package `M`"
6. "where constant `K` is used"
7. "the callers of function `validate(...)`"

## Non-goals for v1 (moved into the forward plan, not cut forever)

Cut deliberately at the start (the most risk for the least value), but scheduled for later:
- **vector search** → graph-RAG in Iter 10 (grounded on the graph, not naive chunks).
- **non-Swift semantics** → **done**: it works through the same index store, and no separate
  layer was needed. The structural layer for those languages is **done too** (2026-08-07), on
  libclang rather than tree-sitter — see [ADR-0004](adr/0004-structural-layer-for-c-family.md).
- **automatic freshness** → **done, but not the way it was planned.** No build hook was needed:
  an ordinary build already updates the index store, and what had to be fixed was the freshness
  signal (`IndexFreshness`, P5 of ADR-0003).

Still a non-goal: a real-time file watcher (continuously watching the filesystem).

## Non-goals after the Apple-environment specialisation (2026-08-09)

[ADR-0005](adr/0005-apple-environment-specialisation.md) narrows the product to the Apple
environment — Swift with Objective-C, C and C++; SwiftPM and Xcode; iOS/macOS/watchOS/tvOS/visionOS
— and trades breadth for a quality standard inside it. Breadth is held by Serena (LSP, 40+
languages, MIT, alive); the Swift-specific competitors are archived or unmaintained. These move
from "later" to "not us":

- **Languages outside the Apple environment** (#36 beyond the C family): Rust, Go, Python,
  Java/Kotlin, TypeScript.
- **Linux** — the semantic backend is tied to the index store and the Xcode toolchain.
- **Cross-project intelligence** (#22) and **graph-RAG intent search** (#18) — breadth of another
  kind, same reasoning.
- **Refactoring as a service** (#20) — Serena's ground, and it requires giving up read-only, which
  is what the tool's trust rests on.
- **"Negative space"** (#43) stays listed but is **not taken** without an answer to "how are we
  better than [Periphery](https://swiftpackageindex.com/peripheryapp/periphery)" — seven years old,
  on the same index store.
- **Interface Builder** (`.storyboard`, `.xib`) — not read, and not planned. A class named only from
  a nib is invisible to the tool, which the documentation states outright rather than leaving to be
  discovered. Measured on the reference project: 56 storyboards, 270 xibs, 376 classes bound from
  them — and **zero** classes that live only there, so the loss is an undercount in impact analysis,
  never a false "nobody uses this". See [ADR-0007](adr/0007-no-interface-builder.md).

What replaces them is depth: an index has an identity (platform, configuration, targets, coverage),
a store is chosen by coverage rather than mtime, `#if` is reported alongside semantic results
instead of only in place of them, and provenance names the build an answer describes.
