# Contributing to sextant

**English** | [Русский](CONTRIBUTING.ru.md)

Thanks for considering it. This document covers the practical side; if you are changing code,
read [AGENTS.md](AGENTS.md) as well — it holds the invariants that are not visible from the
source.

## Getting set up

You need macOS 13+ and a Swift 6.2 toolchain (Xcode 26 or newer).

```bash
git clone https://github.com/RSafargalin/sextant.git
cd sextant
swift build && swift test
```

The semantic layer additionally needs `libIndexStore.dylib`, which sextant locates through
`xcrun --find swiftc`. If something is missing, `sextant doctor --project .` will say what and
what to do about it. The syntactic commands (`map`, `api`, `search`, `lint`, `changed`) work
without any of it.

## Before you open a pull request

```bash
make ci
```

That is build + tests + sextant linting its own sources. CI runs the same thing plus the
golden semantic regression set, so a green `make ci` locally is a good predictor.

Please also:

- Add a test for the behaviour you changed. This project has been burned specifically by
  happy-path tests: the daemon deadlock, the wrong-project bug and the freshness bug all had
  passing tests around them. Test the awkward case — large output, a foreign directory, a
  dropped connection, an empty store.
- Update [CHANGELOG.md](CHANGELOG.md) under `Unreleased` if the change is user-visible.
- Keep commit messages in the conventional-commits style (`fix(mcp): …`, `feat(cli): …`).

## What makes a change likely to be accepted

The project has a stated bias, and it is worth knowing before you invest effort:

**Correctness over capability.** The core promise is that sextant does not return a confident
wrong answer. A feature that is fast and usually right is worse than no feature, because an
agent cannot tell the difference. If a result is heuristic or came from a textual fallback, it
must say so in the output.

**Evidence over assertion.** "This is faster" is not a claim until there is a measurement.
`bench` exists for this, and [docs/benchmarks.md](docs/benchmarks.md) is the standard: numbers
measured on public repositories, at a pinned commit, with the commands included so a reader
can re-run them.

**One layer, not four patches.** If you find yourself adding a special case to something that
already has special cases, that is usually a sign the layer underneath is wrong. Index
freshness went through exactly this: four mechanisms in four places were replaced by one.

**Scope.** Non-goals for v1 are real: no file watcher, no vector search, no non-Swift
semantics. They are listed in the README with reasons, and several are scheduled for later
iterations in [docs/roadmap.md](docs/roadmap.md) rather than rejected forever.

## Reporting a bug

Use the issue template — it asks for the things that actually determine the answer: the exact
command, the project layout (SPM / Xcode workspace / mixed), and the output of
`sextant doctor`. A large share of reports come down to which index store was selected, and
`doctor` shows that directly.

If the bug is that sextant returned a **wrong or empty answer** rather than an error, say so
explicitly and include what the correct answer was and how you know. That class of bug is the
most important one in this project and the hardest to spot.

Security issues go through [SECURITY.md](SECURITY.md), not the public tracker.

## Cutting a release

For maintainers: [RELEASING.md](RELEASING.md) covers the version bump, the tag, what the
release workflow does on its own, and the formula update in the tap.

## Documentation languages

Documents written for people — README, this file, SECURITY, CHANGELOG, CODE_OF_CONDUCT and the
benchmarks — ship in both languages: the English version is canonical, the Russian one
(`*.ru.md`) follows it. Where they disagree, English wins. If you change one, change the other
in the same pull request.

English only, with no translation: CLI help, MCP tool descriptions, error messages, code
comments and `AGENTS.md`. Tool descriptions are sent to the model on every session, and a
second language there doubles the token cost in exactly the place this tool exists to make
cheaper.

The architecture decision records under `docs/adr/` and the roadmap are in Russian. They are a
historical record of how the tool got here and are not being retranslated.
