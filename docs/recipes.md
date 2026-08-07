# Recipes — the questions, and the commands that answer them

**English** | [Русский](recipes.ru.md)

The README lists commands. This page lists **questions**, because that is what you actually have
when you sit down: not "which flag does `blast` take" but "is this type safe to delete".

Every block below was run, not written. To reproduce any of it:

```bash
git clone https://github.com/Alamofire/Alamofire.git && cd Alamofire
git checkout 0455bfb
sextant index          # a build, ~1 minute; the semantic answers need it
```

Output is trimmed where marked `…`; everything else is verbatim.

---

## Is this type safe to delete?

```console
$ sextant blast Session
── blast radius: Session [class]
   a change would touch: 7 files · 25 usages · 0 calls
     Source/Alamofire.swift
     Source/Core/Session.swift
     Source/Features/AuthenticationInterceptor.swift
     …
```

One command instead of grepping a name and opening what it hits. `blast` counts usages, call
sites and implementations, so "0 calls" for a class is the answer, not a gap — a type has no call
sites. If the number is small, read the files; if it is 25 across 7, that is your review.

## What does this type expose?

```console
$ sextant api --type Session
# Public API  •  declarations: 51
## Source
Source/Core/Session.swift
  class Session: @unchecked Sendable  — `Session` creates and manages Alamofire's `Request` types …
    static let `default`  — Shared singleton instance used by all `AF.request` APIs …
    let session: URLSession  — Underlying `URLSession` used to create `URLSessionTasks` …
    …
```

Signatures and doc summaries, no bodies — on the benchmark set that is 79–91% fewer bytes than
reading the sources. `--package` for a whole target, `--scope` for a subdirectory.

## Who actually calls this, through the protocol?

```console
$ sextant callers validate
── validate(policy:errorProducer:)  [instanceMethod]
   def: Source/Features/ServerTrustEvaluation.swift:521:17  public func validate(policy: SecPolicy, …) throws {
   calls: 3 in 1 file(s)
     Source/Features/ServerTrustEvaluation.swift: 190, 624, 639
```

A call through a protocol lands on the requirement, and `callers` follows that: it accounts for
the `overrideOf` relation, which a text search cannot. Add `--full` for the lines themselves.

## Everything about one symbol, in a single call

```console
$ sextant context RetryResult
── RetryResult  [enum]
   def: Source/Features/RequestInterceptor.swift:67  public enum RetryResult: Sendable {
   usages: 17
     • Source/Core/Request.swift:1271  func retryResult(for request: Request, dueTo error: AFError, …)
     • Source/Core/Session.swift:1349  public func retryResult(for request: Request, …) {
     …
```

Definition, usages, callers, callees and hierarchy in one answer. This is the command to reach
for first — the rest are for when you already know which half you need.

## Who implements this protocol?

```console
$ sextant impls RequestInterceptor
── RequestInterceptor: 7
   • AuthenticationInterceptor [class]  Source/Features/AuthenticationInterceptor.swift:160  …
   • OfflineRetrier [class]  Source/Features/OfflineRetrier.swift:31  …
   • DeflateRequestCompressor [struct]  Source/Features/RequestCompression.swift:39  …
   …
```

From the compiler's index, so a conformance declared in an extension counts too — and one spelled
in a `where` clause is not missed the way a grep for `: RequestInterceptor` would miss it.

## What is this type built on?

```console
$ sextant supertypes DataRequest
── DataRequest: 2
   • Request [class]  Source/Core/DataRequest.swift:28  public class DataRequest: Request, @unchecked Sendable {
   • Sendable [protocol]  Source/Core/DataRequest.swift:28  public class DataRequest: Request, @unchecked Sendable {
```

The other direction from `impls`: bases and protocols rather than conformers.

## How does a call reach this function?

```console
$ sextant hierarchy validate --callers --depth 2
# call hierarchy (← callers, depth 2)
validate(policy:errorProducer:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:521
  evaluate(_:forHost:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:190
  performDefaultValidation(forHost:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:624
    evaluate(_:forHost:) [instanceMethod]  Source/Features/ServerTrustEvaluation.swift:116
    …
```

Transitive, with cycle detection. `--callees` walks the other way: what this function ends up
calling.

## What does this function actually do?

```console
$ sextant body cURLDescription
── Source/Core/Request.swift:1179
public func cURLDescription() -> String {
        guard
            let request = lastRequest,
            let url = request.url,
            …
```

`defs` and `context` give the signature; `body` gives the whole declaration. Use it instead of
opening the file and scrolling to a line number.

## What changed on this branch, symbol by symbol?

```console
$ sextant changed --from HEAD~5 --to HEAD
Source/Core/Request.swift
  − Request.func withState(perform: (State) -> Void)

Source/Core/Session.swift
  + Session.struct MutableState
  + Session.let mutableState
  − Session.var activeRequests: Set<Request>
```

Not a line diff: declarations added, removed, or changed signature, qualified by their type. A
reformatting commit produces nothing here, which is the point. What it could not compare — a file
with no compile flags, a revision that does not parse — is named rather than counted as unchanged.

## Where do I start reading this repository?

```console
$ sextant map --pagerank
# PageRank map (files by centrality)

Source/Core/AFError.swift
  enum AFError: Error, Sendable
  extension Error
  …
```

Files ranked by how much the rest of the code depends on them, from the reference graph in the
index. Plain `map` gives the same map in file order under a token budget.

## Find a shape, not a string

```console
$ sextant search 'try! $X'
Tests/TestHelpers.swift:316:20: try! asURL()

total: 2
```

`$X` is a hole, `$$$` absorbs any number of arguments. The match is structural, so a `try!` inside
a comment or a string is not one. Objective-C, C and C++ go through clang and need the flags from
`sextant index`; whatever cannot be read is named, never counted as "no matches".

## Is my setup actually working?

```console
$ sextant doctor
# sextant doctor — …/scratchpad/alamofire
✅ Swift sources: 59 files
✅ libIndexStore: …/usr/lib/libIndexStore.dylib
✅ index store: .build/x86_64-apple-macosx/debug/index/store
✅ index opened: 1 store(s)

✅ ready — `sextant mcp` will work (semantics and structure)
```

Run this first when an answer looks wrong. It says which index it found, whether it is fresh, and
what is missing — including whether another `sextant` on your `PATH` is the one really running.

---

## Keeping this page honest

Every block here was produced by running the command against Alamofire at `0455bfb`. Output drifts
as the tool changes, and documentation that drifts silently is worse than none — so re-running
these before a release is part of the checklist in
[RELEASING.md](../RELEASING.md#1-prepare-the-version). When the output moves, update the blocks
and, if the package moved, the commit.
