# AGENTS.md — working on sextant

Operational notes for anyone (human or agent) editing this repository. What the tool *is*
belongs in [README.md](README.md); the iteration history and the reasoning behind decisions
belong in [docs/](docs/). This file is only what you need in order to change the code without
breaking something invisible.

## Build and verify

```bash
swift build && swift test          # 590 tests
make ci                            # build + test + self-lint — run this before committing
swift test --filter "<suite name>" # one suite
```

`make lint` runs sextant on its own sources with `sextant-rules.json`. The tool is dogfooded:
if a change makes `lint` noisy on this repository, that is a finding about the change.

## How a change lands

Every change goes through a branch and a pull request — maintainer changes included. `main` is
protected: it takes no direct pushes, and a pull request merges only once CI is green on it.

```bash
git switch -c fix/what-it-fixes
# … work, `make ci` …
git push -u origin HEAD && gh pr create
```

The rule is written here because it was broken here. Five commits were pushed straight to `main`
in one session, the last of them a change across twenty-one files, on the strength of a "commit
straight to main" that had been said once about a one-line release chore. Nothing broke, and that
is not the point: a green local `make ci` is a predictor, while CI on a pull request is a gate, and
a twenty-one-file change with no reviewable unit is not reviewable in principle.

The protection is what makes this a rule rather than a resolution. It applies to administrators
too — otherwise it would guard against everyone except the account that actually pushes here. An
emergency turns it off in the repository settings, deliberately and visibly, which is the whole
difference from bypassing it by habit.

## Layout

- `Sources/SextantCore` — all logic, testable. Anything worth a test lives here.
- `Sources/sextant` — thin executable: argument dispatch, rendering, process exit. Keep it
  thin; the reason the codebase was refactored once already is that 1257 lines of
  `main.swift` were untestable.
- `Tests/SextantCoreTests` — behavioural tests, plus a fixture package under
  `Tests/Fixtures/IndexFixture` used to exercise a real IndexStoreDB.
- `plugins/sextant` — the Claude Code plugin: the MCP registration, a skill and a command. It
  ships no code of its own beyond two launcher scripts, registers no hooks (a hook that writes
  from the moment it is installed is the user's decision, not an install's), and it must not
  restate the MCP tool list — `MCPTools.definitions()` is that list, and the skill describes when
  to ask rather than what exists. `.claude-plugin/marketplace.json` at the root is what serves it.

## The stability contract

These are public surface under semver. Renaming one is a breaking change, not a cleanup:

- CLI command names and flags
- `--json` output schemas
- MCP tool names and their input schemas
- exit codes (currently `0` success, `2` usage error)

## Single sources of truth — do not add a second one

This codebase has been bitten by duplicated truth twice; both times it produced a silently
wrong answer rather than a crash.

- **`CommandCatalog`** generates help text, per-command help, and flag validation. Never write
  help text or a flag list anywhere else.
- **`MCPTools.definitions()`** is the only declaration of the MCP surface; `instructions` are
  generated from it. Adding a tool is one edit — and the dispatcher test fails if you forget
  the handler. Do not hand-maintain a parallel list.
- **`IndexFreshness`** is the only place that decides whether an index is fresh, and the only
  place that reads a store's timestamp. It judges on one of two bases and every label names which:
  - **the snapshot** `sextant index` records after it builds a store (`IndexSnapshot`, in
    `~/Library/Caches/sextant/index-snapshot/`): the sources it built from (`SourceSnapshot` — in
    git the `HEAD` commit plus the blob hash of every source that differed from it, outside git
    every source), a fingerprint of the store, and the build record. It is trusted only while the
    store's units timestamp still matches the recorded one (O(1); units are not re-listed per
    query). Its git commands run with `--no-optional-locks`, so a check never writes `.git/index`,
    and a failed git command makes the comparison impossible rather than empty. Freshness is then a comparison of content, returning the
    changed files; manifests, toolchain and a failed build are separate reasons.
  - **build time**, for every store without a trusted snapshot: the mtime of `<store>/v*/units`
    (a build that writes the store rewrites unit files without touching the store directory)
    against the sources' modification times.
  Selecting or judging a store by directory mtime is the specific bug that made semantic queries
  go blind; if you need a freshness signal, call this layer. Nothing about freshness may be
  memoised across requests in `serve` or `mcp`.
- **`TranslatedIndex`** is the only place a symbol answer is stated against the current text. Every
  index-backed command and MCP tool opens it (`openTranslatedIndex`, or the per-call one in
  `mcp`); none reads `IndexStoreSet` for positions directly. Over an index stale against its
  snapshot it consumes the report `IndexFreshness` gave — it never judges freshness again — and
  through `IndexDrift` maps each position in a changed file onto the current text by a line diff
  against the indexed text (git's object for a file clean at index time, otherwise the copy
  `sextant index` keeps in `~/Library/Caches/sextant/index-snapshot-text/`), marks what cannot be
  mapped `unconfirmed` (never drops it), lists text matches the index does not confirm as
  candidates (never counted), and notes changed declarations. `ReferencePositions.verified` runs
  before the mapping, against the indexed text. It also restates every column the store recorded
  (`IndexColumns`, from the text the position was recorded in). Beyond that, on a fresh index, or
  on the build-time basis, it is a pass-through, and the output must stay byte-for-byte what it
  was — `StaleAnswerTests` and the JSON-key test in `IndexDriftTests` guard that.
- **`SourceColumn`** is the only place a column is converted into the one reported unit: 1-based,
  in UTF-16 code units, in text, `--json` and MCP alike. The index store, SwiftSyntax and libclang
  all count bytes of UTF-8; each restates its columns through it (`IndexColumns`, `SwiftColumns`,
  `ByteLines`), never with arithmetic of its own. A position whose line cannot be read states no
  column (nil), never one in bytes. `ColumnUnitTests` holds every layer to the same column.
- **`StoreSelection.resolve`** is the only place that decides which stores answer: with no policy
  set, the rule that a store `sextant index` built goes first (a package's own index tree, or the
  umbrella in the cache — a candidate beside the others, never in place of them), then the
  configuration filter; with a policy, the policy over every usable candidate. Callers print
  `explanation(of:)`; they do not re-derive the decision, and no locator picks a store on its own.
  What refreshes a store is `StoreSelection.refreshAdvice` — advice to rebuild is never written
  without it.
- **`Command`** is the only way another program is started: stdin is the null device unless input
  is passed on purpose, a helper run while a query is answered has a timeout and a timed-out one
  is a failure (`Command.Failure`), never an empty success. Do not create a `Process` elsewhere.
- **`CacheNamespace`** names every persistent cache, and **`CacheEviction`** is the one routine
  that removes anything from `~/Library/Caches/sextant` (superseded versions, entries whose store
  or project is gone). It runs from `sextant index` and `doctor`, never from a query. A new cache
  directory needs a rule there, or it grows forever.

## Code conventions

- Names in English, following the Apple API Design Guidelines. No `*Manager` / `*Service`
  suffixes. A file is named after its principal type.
- Comments describe **behaviour**, not decisions. `/// Loads data on first appearance.` is a
  comment; `// we use a struct here because…` is not — that belongs in an ADR.
- No references to ADRs, issues, or discussions in code comments.
- Comments, CLI help, MCP tool descriptions and error messages are English. Docs written for
  people are bilingual (`*.ru.md` alongside the canonical English); `docs/adr/` stays Russian as
  a historical record. See CONTRIBUTING for the full rule.

## Evidence discipline

Claims in this project carry a confidence level, and the docs use them explicitly
(`Gate (L3)`, `verified L4`):

| | Meaning |
|---|---|
| **L1** | asserted — opinion or memory, no source |
| **L2** | documented — a source exists |
| **L3** | verified in code — cited as `file:line` |
| **L4** | verified against reality — an actual run or experiment |
| **L5** | guarded by automation — a gate, an assert, a test |

The rule that matters when you report on your own work: **never present an unverified claim
as a fact.** If you did not run it, say so. Anything user-facing that is high-risk needs L3 or
better. This is not ceremony — the tool's entire value proposition is that it does not return
confident wrong answers, and a contributor who reports the same way is part of that.

## Things that will bite you

- **`sextant index` executes the target project's build** — its `Package.swift`, its SwiftPM
  plugins, its Xcode run-script phases. Never point it at a repository you do not trust. The
  MCP server deliberately refuses to trigger builds; keep it that way.
- **`sextant index` builds a SwiftPM package in `.build/sextant-index`, not in `.build`.** That
  tree is only ever built with the index store on, so its store covers every file that compiles
  whatever was built before — in a tree built without the store, SwiftPM's Swift Build system
  compiles nothing and writes nothing. An ordinary `swift build` does not refresh that store;
  `sextant index` or `--reindex` does. A store an ordinary build writes in `.build` is a second
  candidate; with no store policy set the one `sextant index` built answers, and an explicit
  policy decides otherwise. Tests find stores and binaries through
  `BuildProducts`, never through a hard-coded layout.
- **Semantic commands need a built index store.** A test that queries semantics without one
  will pass vacuously. The integration fixture exists so this does not happen silently.
- **Do not add a fourth patch for index staleness.** Four separate mechanisms existed once;
  they were replaced by one layer, `IndexFreshness`. Its snapshot basis replaced the mtime
  comparison for stores `sextant index` built, inside that layer, and the mtime comparison stays
  there as the fallback for every other store. A new special case is a signal that the layer is
  wrong, not that a patch is missing.
- **Benchmarks must stay reproducible on public repositories** — see
  [docs/benchmarks.md](docs/benchmarks.md). A number that cannot be re-measured by a reader is
  not evidence.
