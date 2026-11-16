# Benchmarks — reproducible, on public repositories

**English** | [Русский](benchmarks.ru.md)

Every number here was measured on public open-source Swift packages at a pinned commit, with
commands you can run yourself. Nothing depends on a private codebase.

**Environment:** macOS 27.2.1, arm64 (Apple M5 Max), sextant built from source at `b658d66` — the changes after 0.9.1 that are not released yet. All three scenarios were re-measured on 2026-11-16 at the commits named below. The machine is not the one the earlier rows were timed on, so the timings of Scenario C do not compare with them; byte counts do not depend on the machine. Every earlier measurement, and how the numbers moved between releases, is in the [measurement history](measurements/history.md).

**Repositories** (shallow clones, pinned):

| Repository | Commit | `.swift` files in sources |
|---|---|---|
| [Alamofire/Alamofire](https://github.com/Alamofire/Alamofire) | `0455bfb` | 43 |
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | `2f77f2f` | 55 |
| [apple/swift-numerics](https://github.com/apple/swift-numerics) | `899af71` | 34 |
| [apple/swift-nio](https://github.com/apple/swift-nio) | `7297328` | 309 |
| [swiftlang/swift-syntax](https://github.com/swiftlang/swift-syntax) | `60e8eb8` | 318 |

## What is measured, and what is not

The unit is **bytes of output**, because bytes are exactly reproducible. A token count would
be more directly meaningful for an LLM budget, but it depends on the tokenizer; as a rough
guide, divide by 4. The tool's own `bench` command is deliberate about this too — it labels
its payload figure a *relative proxy for volume, not tokens*.

The comparison is only valid for the task stated in each scenario. `api` returns
**signatures and doc summaries, not bodies** — it answers "what is the public surface of
this", not "how is this implemented". For the latter, read the source; sextant's `body`
command exists for exactly that.

## Scenario A — learn the public surface of a package

The question: *"what does this package expose?"* — the thing an agent asks before touching
an unfamiliar dependency.

- **sextant:** `sextant api --project <repo> --scope <sources>`
- **Baseline:** reading every `.swift` file under the sources directory.

| Repository | Declarations | `api` bytes | Source bytes | Saving |
|---|---:|---:|---:|---:|
| Alamofire | 1 430 | 195 506 | 803 997 | **75.7%** |
| swift-argument-parser | 433 | 52 122 | 461 564 | **88.7%** |
| swift-numerics | 411 | 31 993 | 181 937 | **82.4%** |
| swift-nio | 4 947 | 565 324 | 4 464 792 | **87.3%** |
| swift-syntax | 15 554 | 1 562 973 | 6 673 159 | **76.6%** |

Saving is stable in the **76–89%** band across a 9× spread in repository size. The two ends of
the band are the two kinds of code that are already close to pure surface: swift-syntax is largely
generated, with a very high declaration-to-body ratio, and Alamofire carries doc comments on almost
every declaration — `api` keeps their summaries, which is most of what it prints.

Compared with the same measurement at 0.7.0, every surface is larger: Alamofire 973 → 1 226
declarations, swift-nio 3 672 → 4 259. Nothing about the packages changed — the commits are the
same — the surface did. Declarations behind `#if` are now listed with the condition they are
guarded by, and an internal `extension` that carries public members is now part of the surface it
carries. Both were missing before, so the old numbers were a saving measured against an answer
that was too small.

Compared with 0.9.1, every surface is larger again: Alamofire 1 226 → 1 430 declarations, swift-nio
4 259 → 4 947, swift-syntax 13 967 → 15 554, and the saving is 1–3 points lower. The commits are the
same; `api` now lists what it used to leave out — members nested more than one level deep,
extensions that only add a conformance, `operator` and `precedencegroup` declarations — and prints
fuller signatures (attributes, accessors, modifiers). As before, the earlier saving was measured
against an answer that was too small.

The 0.9.0 figures this page published for swift-nio (5 055) and swift-numerics (497) could not be
reproduced with the 0.9.0 binary that was released; the [history](measurements/history.md) keeps
both and says what is known about why.

## Scenario B — learn one type

The question: *"what is `Session` / `ByteBuffer` / `Complex`?"* — the most common navigation
step in practice.

- **sextant:** `sextant api --project <repo> --scope <sources> --type <T>`
- **Baseline:** reading every file that declares **or extends** `T`. Reading only the file
  with the primary declaration is not an equivalent answer — in Swift the public surface of a
  type is routinely spread across many extension files, and `api --type` gathers all of them.

| Repository | Type | Files holding the surface | `api` bytes | Source bytes | Saving |
|---|---|---:|---:|---:|---:|
| Alamofire | `Session` | 1 | 13 499 | 85 330 | **84.2%** |
| swift-argument-parser | `ParsableCommand` | 1 | 1 770 | 10 088 | **82.5%** |
| swift-numerics | `Complex` | 11 | 7 264 | 48 287 | **85.0%** |
| swift-nio | `ByteBuffer` | 22 | 68 258 | 596 934 | **88.6%** |
| swift-syntax | `TokenSyntax` | 13 | 14 409 | 249 302 | **94.2%** |

The saving grows with how widely a type is extended, which is also when finding the surface
by hand is hardest.

> **A methodology note, because it changed the result.** The first version of this scenario
> compared `api --type` against the single file holding the primary declaration. That made
> `Complex` and `TokenSyntax` look like *losses* (−9% and −85%): `api` was returning the
> surface from a dozen extension files while the baseline was one small file. The two sides
> were not answering the same question. The table above uses the corrected baseline.

## Scenario C — cost of a repeated query (content-hash cache)

Parse results are cached by content hash, so an unchanged tree is not re-parsed. Same command
as Scenario A, run twice:

| Repository | Cold | Warm | Speed-up |
|---|---:|---:|---:|
| swift-numerics | 0.27 s | 0.04 s | 7× |
| swift-argument-parser | 0.70 s | 0.05 s | 14× |
| swift-nio | 5.92 s | 0.11 s | 54× |
| swift-syntax | 10.59 s | 0.15 s | **71×** |

The cold figure is the honest cost of first contact with a large repository: a full
SwiftSyntax parse of 318 files takes about ten seconds on this machine (about a minute on the
x86_64 machine of the 0.9.1 measurement). Every subsequent query on an unchanged tree
is sub-second.

The fixed cost of 0.25–0.3 s per run that the 0.9.1 measurement reported and could not explain is
gone. Measured on this machine with release builds of both, warm: `main` 0.23–0.31 s on the four
repositories, this build 0.04–0.13 s — about 0.19 s less on each, whatever its size. The change
that fits it is how a helper process is awaited (`git` and `xcrun` runs each cost 65–70 ms more
than they ran); it was not isolated from the other changes by a separate measurement (see the
[history](measurements/history.md)).

These timings come from a **debug** build (`swift build`), which is what you get from a
source checkout. SwiftSyntax parsing is substantially slower without optimisation, so the
cold column is pessimistic relative to the release binary shipped in the Homebrew formula and
the GitHub release. The byte counts in Scenarios A and B are unaffected by build
configuration.

## Reproducing this

```bash
git clone --depth 1 https://github.com/apple/swift-nio.git
sextant api --project swift-nio --scope Sources | wc -c
find swift-nio/Sources -name '*.swift' -exec cat {} + | wc -c
```

No index store and no build are required for any measurement on this page — `api` works on
the syntactic layer. That also means none of this executes the cloned project's build system.
