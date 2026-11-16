# Measurement history

**English** | [Русский](history.ru.md)

[benchmarks.md](../benchmarks.md) shows the numbers of the current release. This page keeps every
measurement that page ever published, so a trend can be read and a release can be looked back on.

Rules, because a history is only worth what its rows are:

- **Append, never rewrite.** A row is a record of what was measured. If it turns out to be wrong,
  it stays and gets a note; the corrected number is a new row.
- **Name the binary.** A row says what produced it — a released binary, or a build from source at
  a commit — because the two have differed (see 0.9.0 below). Rows from before this page existed
  say "not recorded" where nobody wrote it down.
- **Same inputs.** Every row uses the repositories and commits listed on the benchmarks page; a
  row on other inputs is a new table, not a new row.
- **A release that was not re-measured adds no row.** Carrying the previous numbers forward under
  a new version would claim a measurement that did not happen.

Byte counts do not depend on the build configuration; timings do, and on the machine.

## Scenario A — public surface of a package (`api --scope`)

| Version | Measured | Produced by | Repository | Declarations | `api` bytes | Source bytes | Saving |
|---|---|---|---|---:|---:|---:|---:|
| 0.7.0 | 2026-08-05 | not recorded | Alamofire | 973 | 125 043 | 803 997 | 84.5% |
| 0.7.0 | 2026-08-05 | not recorded | swift-argument-parser | 374 | 46 503 | 461 564 | 90.0% |
| 0.7.0 | 2026-08-05 | not recorded | swift-numerics | 328 | 24 899 | 181 937 | 86.4% |
| 0.7.0 | 2026-08-05 | not recorded | swift-nio | 3 672 | 414 162 | 4 464 792 | 90.8% |
| 0.7.0 | 2026-08-05 | not recorded | swift-syntax | 13 961 | 1 372 591 | 6 673 159 | 79.5% |
| 0.9.0 † | 2026-08-17 | not recorded | Alamofire | 1 226 | 170 753 | 803 997 | 78.8% |
| 0.9.0 † | 2026-08-17 | not recorded | swift-argument-parser | 376 | 46 724 | 461 564 | 89.9% |
| 0.9.0 † | 2026-08-17 | not recorded | swift-numerics | 497 | 31 911 | 181 937 | 82.5% |
| 0.9.0 † | 2026-08-17 | not recorded | swift-nio | 5 055 | 518 860 | 4 464 792 | 88.4% |
| 0.9.0 † | 2026-08-17 | not recorded | swift-syntax | 13 989 | 1 374 492 | 6 673 159 | 79.4% |
| 0.9.0 | 2026-11-04 | Homebrew 0.9.0 | Alamofire | 1 226 | 170 754 | 803 997 | 78.8% |
| 0.9.0 | 2026-11-04 | Homebrew 0.9.0 | swift-argument-parser | 376 | 46 725 | 461 564 | 89.9% |
| 0.9.0 | 2026-11-04 | Homebrew 0.9.0 | swift-numerics | 400 | 30 009 | 181 937 | 83.5% |
| 0.9.0 | 2026-11-04 | Homebrew 0.9.0 | swift-nio | 4 259 | 489 671 | 4 464 792 | 89.0% |
| 0.9.0 | 2026-11-04 | Homebrew 0.9.0 | swift-syntax | 13 967 | 1 373 566 | 6 673 159 | 79.4% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | Alamofire | 1 226 | 170 754 | 803 997 | 78.8% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-argument-parser | 376 | 46 725 | 461 564 | 89.9% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-numerics | 400 | 30 009 | 181 937 | 83.5% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-nio | 4 259 | 489 671 | 4 464 792 | 89.0% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-syntax | 13 967 | 1 373 566 | 6 673 159 | 79.4% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | Alamofire | 1 430 | 195 506 | 803 997 | 75.7% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-argument-parser | 433 | 52 122 | 461 564 | 88.7% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-numerics | 411 | 31 993 | 181 937 | 82.4% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-nio | 4 947 | 565 324 | 4 464 792 | 87.3% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-syntax | 15 554 | 1 562 973 | 6 673 159 | 76.6% |

† **Not reproducible with the released binary.** The 0.9.0 numbers published on 2026-08-17 do not
match what the 0.9.0 binary shipped through Homebrew prints on the same commits: swift-nio 5 055
declarations against 4 259, swift-numerics 497 against 400, swift-syntax 13 989 against 13 967,
and one byte more or less elsewhere. The re-measurement on 2026-11-04 is byte-for-byte identical
between the Homebrew 0.9.0 binary and the 0.9.1 source build, so `api` did not change between the
two releases. What produced the published numbers was not recorded — most likely a build from
before the last changes of 0.9.0. That is why the "Produced by" column exists.

## Scenario B — one type (`api --type`)

| Version | Measured | Produced by | Repository | Type | Files | `api` bytes | Source bytes | Saving |
|---|---|---|---|---|---:|---:|---:|---:|
| 0.7.0 | 2026-08-05 | not recorded | Alamofire | `Session` | 1 | 11 744 | 85 330 | 86.3% |
| 0.7.0 | 2026-08-05 | not recorded | swift-argument-parser | `ParsableCommand` | 1 | 1 728 | 10 088 | 82.9% |
| 0.7.0 | 2026-08-05 | not recorded | swift-numerics | `Complex` | 11 | 6 983 | 48 287 | 85.6% |
| 0.7.0 | 2026-08-05 | not recorded | swift-nio | `ByteBuffer` | 22 | 60 885 | 596 934 | 89.9% |
| 0.7.0 | 2026-08-05 | not recorded | swift-syntax | `TokenSyntax` | 13 | 13 894 | 249 302 | 94.5% |
| 0.9.0 | 2026-08-17 | not recorded | Alamofire | `Session` | 1 | 13 110 | 85 330 | 84.6% |
| 0.9.0 | 2026-08-17 | not recorded | swift-argument-parser | `ParsableCommand` | 1 | 1 720 | 10 088 | 83.0% |
| 0.9.0 | 2026-08-17 | not recorded | swift-numerics | `Complex` | 11 | 6 975 | 48 287 | 85.6% |
| 0.9.0 | 2026-08-17 | not recorded | swift-nio | `ByteBuffer` | 22 | 64 385 | 596 934 | 89.2% |
| 0.9.0 | 2026-08-17 | not recorded | swift-syntax | `TokenSyntax` | 13 | 13 886 | 249 302 | 94.4% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | Alamofire | `Session` | 1 | 13 110 | 85 330 | 84.6% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-argument-parser | `ParsableCommand` | 1 | 1 720 | 10 088 | 83.0% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-numerics | `Complex` | 11 | 6 975 | 48 287 | 85.6% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-nio | `ByteBuffer` | 22 | 64 385 | 596 934 | 89.2% |
| 0.9.1 | 2026-11-04 | source build, `caab3f5` | swift-syntax | `TokenSyntax` | 13 | 13 886 | 249 302 | 94.4% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | Alamofire | `Session` | 1 | 13 499 | 85 330 | 84.2% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-argument-parser | `ParsableCommand` | 1 | 1 770 | 10 088 | 82.5% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-numerics | `Complex` | 11 | 7 264 | 48 287 | 85.0% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-nio | `ByteBuffer` | 22 | 68 258 | 596 934 | 88.6% |
| after 0.9.1, unreleased | 2026-11-16 | source build, `b658d66` | swift-syntax | `TokenSyntax` | 13 | 14 409 | 249 302 | 94.2% |

The 0.9.0 row of this scenario is reproduced exactly by the Homebrew 0.9.0 binary on 2026-11-04.

The rows of 2026-11-16, in both scenarios, are a build from source that is not a release: they
record what the changes after 0.9.1 do to the numbers, and the release that ships them is measured
again. `api` lists more than it did — members nested more than one level deep, extensions that only
add a conformance, `operator` and `precedencegroup` declarations — and prints fuller signatures, so
every surface is larger and the saving 1–3 points lower. The inputs were checked before measuring:
the file counts and the source bytes of all five repositories equal the earlier rows, and a build of
`main` on the same machine printed the 0.9.1 declaration counts (swift-numerics 400, swift-nio
4 259). The "Files" and "Source bytes" columns of this scenario were carried over from the 0.9.1
rows, not counted again — the commits are the same.

## Scenario C — a repeated query (content-hash cache)

Debug build (`swift build`), `SEXTANT_NO_DAEMON=1`, an empty cache for the cold run.

| Version | Measured | Machine | Repository | Cold | Warm | Speed-up |
|---|---|---|---|---:|---:|---:|
| 0.7.0 | 2026-08-05 | macOS 26.5.2, x86_64 | swift-numerics | 1.46 s | 0.18 s | 8× |
| 0.7.0 | 2026-08-05 | macOS 26.5.2, x86_64 | swift-argument-parser | 3.80 s | 0.20 s | 19× |
| 0.7.0 | 2026-08-05 | macOS 26.5.2, x86_64 | swift-nio | 30.45 s | 0.36 s | 84× |
| 0.7.0 | 2026-08-05 | macOS 26.5.2, x86_64 | swift-syntax | 57.57 s | 0.51 s | 112× |
| 0.9.1 | 2026-11-04 | macOS 26.6.2, x86_64 | swift-numerics | 1.75 s | 0.43 s | 4× |
| 0.9.1 | 2026-11-04 | macOS 26.6.2, x86_64 | swift-argument-parser | 3.81 s | 0.44 s | 9× |
| 0.9.1 | 2026-11-04 | macOS 26.6.2, x86_64 | swift-nio | 30.41 s | 0.68 s | 45× |
| 0.9.1 | 2026-11-04 | macOS 26.6.2, x86_64 | swift-syntax | 54.19 s | 0.80 s | 68× |
| after 0.9.1, unreleased | 2026-11-16 | macOS 27.2.1, arm64 (Apple M5 Max) | swift-numerics | 0.27 s | 0.04 s | 7× |
| after 0.9.1, unreleased | 2026-11-16 | macOS 27.2.1, arm64 (Apple M5 Max) | swift-argument-parser | 0.70 s | 0.05 s | 14× |
| after 0.9.1, unreleased | 2026-11-16 | macOS 27.2.1, arm64 (Apple M5 Max) | swift-nio | 5.92 s | 0.11 s | 54× |
| after 0.9.1, unreleased | 2026-11-16 | macOS 27.2.1, arm64 (Apple M5 Max) | swift-syntax | 10.59 s | 0.15 s | 71× |

The cold column held; the warm one roughly doubled, by 0.25–0.3 s on every repository regardless
of its size — a fixed cost added per run, not a cache that stopped working. Where it comes from
is not established, and the macOS version changed in between. Each figure is a single run.

The rows of 2026-11-16 were timed on another machine (arm64 instead of x86_64), so they do not
compare with the rows above them: most of the difference in the cold column is the hardware. The
cold figure is a single run on an empty cache; the warm figure is the median of three runs, which
differed by at most 0.01 s. What does compare is a pair measured on that machine the same day, with
release builds, warm, median of three:

| Repository | `main` (`3797313`) | source build, `b658d66` |
|---|---:|---:|
| swift-numerics | 0.23 s | 0.04 s |
| swift-argument-parser | 0.24 s | 0.04 s |
| swift-nio | 0.28 s | 0.10 s |
| swift-syntax | 0.31 s | 0.13 s |

About 0.19 s less on every repository, whatever its size — the size of the fixed cost the 0.9.1
rows reported. The change that fits it is how a helper process is awaited: each `git` or `xcrun`
run cost 65–70 ms more than it ran, and a command starts several. That attribution was not isolated
by a measurement of its own; the other changes of the same build were in the binary too.

## Adding a row

At a release, after the version bump (see [RELEASING.md](../../RELEASING.md)):

```bash
sextant api --project <repo> --scope <sources> | wc -c                   # scenario A, bytes
sextant api --project <repo> --scope <sources> | head -1                 # scenario A, declarations
sextant api --project <repo> --scope <sources> --type <T> | wc -c        # scenario B
find <repo>/<sources> -name '*.swift' -exec cat {} + | wc -c             # source bytes
```

For scenario C, run the scenario A command twice with `HOME` and `CFFIXED_USER_HOME` pointed at an
empty directory, so the first run is cold for real and nothing else on the machine is touched.
Write down what produced the numbers in the "Produced by" column.
