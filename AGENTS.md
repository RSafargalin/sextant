# AGENTS.md — working on sextant

Operational notes for anyone (human or agent) editing this repository. What the tool *is*
belongs in [README.md](README.md); the iteration history and the reasoning behind decisions
belong in [docs/](docs/). This file is only what you need in order to change the code without
breaking something invisible.

## Build and verify

```bash
swift build && swift test          # 131 tests
make ci                            # build + test + self-lint — run this before committing
swift test --filter "<suite name>" # one suite
```

`make lint` runs sextant on its own sources with `sextant-rules.json`. The tool is dogfooded:
if a change makes `lint` noisy on this repository, that is a finding about the change.

## Layout

- `Sources/SextantCore` — all logic, testable. Anything worth a test lives here.
- `Sources/sextant` — thin executable: argument dispatch, rendering, process exit. Keep it
  thin; the reason the codebase was refactored once already is that 1257 lines of
  `main.swift` were untestable.
- `Tests/SextantCoreTests` — behavioural tests, plus a fixture package under
  `Tests/Fixtures/IndexFixture` used to exercise a real IndexStoreDB.

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
  place that reads a store's timestamp. It reads the mtime of `<store>/v*/units`, because a
  build rewrites unit files without touching the store directory. Selecting or judging a
  store by directory mtime is the specific bug that made semantic queries go blind; if you
  need a freshness signal, call this layer.

## Code conventions

- Names in English, following the Apple API Design Guidelines. No `*Manager` / `*Service`
  suffixes. A file is named after its principal type.
- Comments describe **behaviour**, not decisions. `/// Loads data on first appearance.` is a
  comment; `// we use a struct here because…` is not — that belongs in an ADR.
- No references to ADRs, issues, or discussions in code comments.
- Comments, CLI help, MCP tool descriptions and error messages are English. Docs written for
  people are bilingual (`*.ru.md` alongside the canonical English); `docs/adr/` and the roadmap
  stay Russian as a historical record. See CONTRIBUTING for the full rule.

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
- **Semantic commands need a built index store.** A test that queries semantics without one
  will pass vacuously. The integration fixture exists so this does not happen silently.
- **Do not add a fourth patch for index staleness.** Four separate mechanisms existed once;
  they were replaced by one layer. A new special case is a signal that the layer is wrong,
  not that a patch is missing.
- **Benchmarks must stay reproducible on public repositories** — see
  [docs/benchmarks.md](docs/benchmarks.md). A number that cannot be re-measured by a reader is
  not evidence.
