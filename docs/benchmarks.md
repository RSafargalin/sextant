# Benchmarks — reproducible, on public repositories

**English** | [Русский](benchmarks.ru.md)

Every number here was measured on public open-source Swift packages at a pinned commit, with
commands you can run yourself. Nothing depends on a private codebase.

**Environment:** macOS 26.5.2, x86_64, sextant 0.7.0 (the numbers are a record of that measurement and were not re-run for 0.8.0).

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
| Alamofire | 973 | 125 043 | 803 997 | **84.5%** |
| swift-argument-parser | 374 | 46 503 | 461 564 | **90.0%** |
| swift-numerics | 328 | 24 899 | 181 937 | **86.4%** |
| swift-nio | 3 672 | 414 162 | 4 464 792 | **90.8%** |
| swift-syntax | 13 961 | 1 372 591 | 6 673 159 | **79.5%** |

Saving is stable in the **79–91%** band across a 9× spread in repository size. The largest
repository shows the *smallest* saving: swift-syntax is largely generated code with a very
high declaration-to-body ratio, so its source is already close to being pure surface.

## Scenario B — learn one type

The question: *"what is `Session` / `ByteBuffer` / `Complex`?"* — the most common navigation
step in practice.

- **sextant:** `sextant api --project <repo> --scope <sources> --type <T>`
- **Baseline:** reading every file that declares **or extends** `T`. Reading only the file
  with the primary declaration is not an equivalent answer — in Swift the public surface of a
  type is routinely spread across many extension files, and `api --type` gathers all of them.

| Repository | Type | Files holding the surface | `api` bytes | Source bytes | Saving |
|---|---|---:|---:|---:|---:|
| Alamofire | `Session` | 1 | 11 744 | 85 330 | **86.3%** |
| swift-argument-parser | `ParsableCommand` | 1 | 1 728 | 10 088 | **82.9%** |
| swift-numerics | `Complex` | 11 | 6 983 | 48 287 | **85.6%** |
| swift-nio | `ByteBuffer` | 22 | 60 885 | 596 934 | **89.9%** |
| swift-syntax | `TokenSyntax` | 13 | 13 894 | 249 302 | **94.5%** |

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
| swift-numerics | 1.46 s | 0.18 s | 8× |
| swift-argument-parser | 3.80 s | 0.20 s | 19× |
| swift-nio | 30.45 s | 0.36 s | 84× |
| swift-syntax | 57.57 s | 0.51 s | **112×** |

The cold figure is the honest cost of first contact with a large repository: a full
SwiftSyntax parse of 318 files takes ~a minute. Every subsequent query on an unchanged tree
is sub-second.

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
