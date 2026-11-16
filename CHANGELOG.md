# Changelog

**English** | [Русский](CHANGELOG.ru.md)

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The stability contract covers **CLI flags, JSON output schemas, MCP tool names and their
input schemas, and exit codes**. Breaking any of those requires a major version bump.
Human-readable text output is not covered — parse `--json`, not prose.

## [Unreleased]

### Added

- **Operators and precedence groups are part of the surface.** `api`, `map` and `changed` now list
  `infix operator >>> : CompositionPrecedence`, `prefix operator √` and
  `precedencegroup CompositionPrecedence { associativity: left higherThan: AdditionPrecedence }`;
  they were not extracted at all, so adding or removing one changed nothing in `changed`. `--json`
  gains two values of `kind`: `operator` and `precedencegroup`. The declaration caches move to
  `declarations-v7` and `drift-declarations-v3`; the eviction removes the old versions.

- **An answer over a stale index is stated against the sources as they are now, and says exactly
  where it cannot be.** When the index `sextant index` built is stale against its snapshot, every
  symbol answer — `refs`, `defs`, `callers`, `callees`, `impls`, `supertypes`, `hierarchy`,
  `context`, `blast`, `construct`, `body` and their MCP tools — passes through one layer that maps
  each position in a changed file onto the current text by a line diff against the text the store
  was built from. A position on a line the edit left intact is reported at its current line, as
  confirmed; one on a line that was modified or deleted, or in a deleted file, is kept at the line
  as indexed and marked `[unconfirmed]`, never dropped and never moved to a guess. Places in the
  changed files where the name is now written that no index occurrence accounts for are listed
  apart, as candidates the index does not confirm (a text match: same name, possibly another
  symbol) and never added to a count — identifier tokens in Swift, so comments and string literals
  do not match; a lexical identifier match outside comments and literals in Objective-C, C and
  C++. When a changed Swift file's declarations changed (added, removed, signature) — or a C-family
  header changed — the answer says that uses elsewhere may now resolve differently and names the
  files; a body-only edit says nothing of the kind. `--json` only gains keys: `indexedLine` and
  `unconfirmed` on a position, and a `staleness` object (`changedFiles`, `declarationsChanged`,
  `candidates`, `candidateCount`, `candidateMatching`) on each hit of `refs`/`defs`/`callers`, on
  `context` and on `blast` (which also gains `unconfirmedFiles`); for the commands whose JSON is a
  plain array the note goes to stderr. On a fresh index, and for every store judged by build time,
  output is byte-for-byte what it was. The text of a file clean in git at index time is read back
  from the repository's objects; for a file dirty then (and for every source outside git, up to
  64 MB in all) `sextant index` keeps a copy in `~/Library/Caches/sextant/index-snapshot-text/`,
  addressed by its blob hash and pruned when no snapshot refers to it — never in the project.

- **Metavariables in Swift patterns stand in type, binding, catch and declaration positions, not
  only where an expression can.** `$X as! $T`, `$X as? $T`, `$X is $T`, `let $N: $T = $V`,
  `Array<$T>`, parameter and return types in a `func` pattern; binding names in `let`/`var`,
  `if let`, `guard let`, `for … in` and closure parameters (a binding hole takes any pattern there,
  a tuple included); `catch let $E` and `catch $P` (a pattern may now start with `catch`, and one
  without a body accepts any body); declaration names (`func $F`, `class $C`, `struct $S: $P`,
  `enum $E`, `var $N: $T`); and a parameter written as a bare metavariable — `func $F($P)` is
  exactly one parameter and `func $F($$$)` any number, the same rule as `$X` and `$$$` in an
  argument list. `{ $$$ }` as a type's body absorbs any members. A name repeated across position
  kinds binds the same text (`register($T.self, $X as! $T)`). An interpolation, `"\($X)"`, matches
  an interpolated expression. The placeholder a metavariable becomes before parsing can no longer
  collide with a name the pattern spells out: `SEXTANTMETA_X` written literally used to act as a
  hole.

### Changed

- **A declaration pattern constrains only what it states.** `struct $S: $P { $$$ }` found `struct A: P`
  and skipped `public struct B: P`, `@frozen struct C: P`; `class $C { $$$ }` found no `final class`;
  `func $F($$$) -> $R { $$$ }` found only functions with no modifier, attribute or generic clause —
  on this repository `struct $S { $$$ }` found 3 structs of 120. Modifiers, attributes, a generic
  clause, an inheritance clause and a `where` clause the pattern leaves out may now be on the
  declaration or not; those it writes must be there (`public struct $S { $$$ }` only public ones,
  `final class $C { $$$ }` only final ones, each stated modifier among any others). This holds for
  `struct`, `class`, `enum`, `actor`, `protocol`, `extension`, `func`, `init`, `var`/`let`,
  `typealias` and `subscript` patterns, in `search`, `lint` rules and `structural_search`; a
  function's parameters, effects and result stay compared as written. The `search-v6` and `lint-v6`
  caches replace v5.
- **`construct` counts sites, not lines, and states each at `file:line:column`.** `Vec(…) <+> Vec(…)`
  on one line is two sites; a plain use of the type beside a construction is none — each reference is
  judged at its own column. `--json` gains a `column` key per site (additive).
- **The callers of a property are the calls of its accessors.** `callers area` said `calls: 0` for
  every `area` while `callees demo` listed `getter:area`; it now counts the getter's (and setter's)
  calls and says so — `calls (of its getter): 3` — in `callers`, `context`, `blast`, `hierarchy` and
  their MCP tools. `--json` gains `accessors` on such a hit and `callerAccessors` in `context`
  (additive, absent otherwise). `context` lists a call that lands on an implementation and on the
  requirement it satisfies once.
- **`api --type <name>` naming no public declaration says so** — `No public declaration named 'X'
  here` — instead of `# Public API • declarations: 0`; exit 0, as `refs` answers an unknown symbol (a
  name that is not in the code is a fact about the code, not a usage error). `--json` keeps `[]` and
  says it on stderr. Over MCP `api {"package":"Nope"}` is now an error result naming the known
  packages, as the CLI's exit 2 is.
- **A `case a, b` declaration is named `a, b`** in `api --json` and every other declaration listing;
  it was named after its first case. The declaration cache moves to `declarations-v7`.
- **`--max-files` gives no slot to a package manifest**, which no area command reads as a source:
  `map --max-files 1` on the fixture said "covered 1 of 9" over `Package.swift` and printed an empty
  map. `doctor` and `init` no longer count `Package.swift` as a Swift source.
- **Several stores read together carry a coverage figure** — the union of the files any of them
  covers — so the `union` trust label states it like every other.
- **Completion offers declared values**: `--store-policy` and `--client` their words, `store` its
  subcommands and then the policies, `completion` the shells (bash and zsh, from `CommandCatalog`).
- **`--max-files` bounds every file read, Swift and Objective-C/C/C++ together.** It counted only
  Swift files while clang read every C-family one: in the fixture `map --max-files 1` said
  "covered 1 of 3 file(s)" and listed five C-family files, and `search '$X * 2' --max-files 1`
  matched in `.c` and `.cpp`. The bound is now one sorted list of both, cut to its first N, for
  `map`, `api`, `search`, `lint` and their MCP tools (`maxFiles` in `.sextant.json`), and the
  "covered N of M" line counts the same files. `changed` is not bounded by it: it reads the files
  the diff names. Documented in `--help` and the README.
- **The MCP `api` tool declares its `budget` argument** (an additive schema change: the argument
  already worked). It was read without being declared, so validation never saw it — `"5"`, `2.5`,
  `1e30` and `9223372036854775808` were answered with the default surface and no word; they are now
  `-32602`, as for `repo_map`. A test reads the dispatcher and fails when a handler reads an
  argument its schema does not declare, or declares one it never reads.
- **CLI `lint` refuses a `.sextant.json` it cannot parse** (exit `2`) instead of checking the
  built-in rules in place of the ones the config may name; the MCP `lint` tool already refused it.
  `--rules` still runs.
- **`SEXTANT_CACHE_MAX` of `0` or a negative number is named, and the default is used** — it used to
  turn pruning off without a word, while `abc` was named. One reading decides both.

- **Input that is not understood is refused (exit `2`).** A positional argument a command does
  not take (`refs a b`, `map extra`), an unknown flag after `version`, and flags that contradict
  each other (`hierarchy --callers --callees`, `refs --compact --full`, `map --semantic --pagerank`)
  used to be dropped or decided silently. Arity and exclusive flags are declared in the command
  catalog, which `version` now joins. Over MCP, an integer argument outside the 64-bit range
  (`{"budget": 1e30}`) is `-32602` instead of the default used silently, and `resources/read`
  without a `uri` is `-32602` instead of `-32002 unknown resource`.
- **A token budget has a documented maximum.** `map --budget`, `api --budget` and the MCP `budget`
  above 100000000 are lowered to it, and the answer says so the way a raised minimum is said;
  `--budget 9223372036854775807` used to crash the process (SIGTRAP), and over MCP ended the session.
- **`lint` that checked nothing fails.** A rules file with no patterns, or none any engine could
  compile, printed `✅ No violations found` and exited 0; it now says "nothing was checked" and exits
  `2`, as a rules file that does not parse does (the MCP `lint` tool answers with an error).
- **`index --app` builds where it looks.** With `--derived-data` (now accepted by `index`) or
  `SEXTANT_DERIVED_DATA`, xcodebuild is given `-derivedDataPath`, and a store built with
  `-derivedDataPath <dir>` — `info.plist` and `Index.noindex` in `<dir>` itself — is found.
- **Coverage counts what a unit is built from.** The denominator of `covers N/M files` no longer
  counts package manifests and headers, which are never the main file of a unit, so a complete
  index reads 100%. The `store-coverage` cache moves to v4; `search`/`lint` caches move to v5.
- **Umbrella index: packages without `platforms:` take part**, with SwiftPM's default macOS
  minimum, instead of refusing the whole index; targets no library product reaches are named by
  `index` instead of being left out without a word. README describes the expected layout.
- **`changed` compares Objective-C, C and C++ headers** with the flags of the source that includes
  them, and lists the declarations of a deleted C-family source from the base revision, instead of
  "no compile flags — build the index", advice that could not help.
- **`context` counts callees by symbol**, as `callees` does: `calls: 56 (152 call sites)`.
- **Patterns `Array<$T>`, `Dictionary<$K, $V>` match type positions too** (`let xs: Array<Int>`,
  `-> Array<String>`), and `func $F($P)` / `func $F($$$)` without a body match a declaration with
  any body, as the documentation says; the return type, if written, is still compared.
- **Contract, documented: exit code `1` is a failure that is not a usage error.** The contract
  named only `0` and `2`, while `1` was already what a failed build, a failed write, a git failure
  and a check that found problems returned. `sextant store use` returned `2` (usage error) when
  `.sextant.json` could not be written; it now returns `1`. AGENTS.md and both READMEs list the
  three codes.
- **`changed` lists the members of an extension added or removed whole.** Its header names only
  the type it extends, so `+ extension Foo: Equatable` said nothing of what was added; the members
  now follow it, qualified (`+ Foo.func a()`). The same holds for an Objective-C category. An
  extension that stays is compared member by member, as before. `--json` keeps its shape; the
  `added`/`removed` lists gain those entries.
- **A property whose type is inferred says so.** `public var count = 0` was shown as `var count`,
  as if it had no type; it is now `var count = …` in `api`, `map` and `changed` — the type comes
  from the elided initial value, and none is invented. A change of the initial value is not a
  change of the signature.
- **A budget below the minimum is raised and the answer says so.** `api --budget` below 200, and the
  MCP `repo_map`/`api` budget below 500, were raised without a word; `call_hierarchy` over MCP raised
  a `depth` below 1 the same way. The value used is unchanged, and the answer now names the raise
  (`budget 10 is below the minimum of 500; 500 was used` — on stderr in the CLI, in the answer over
  MCP).
- **`.sextant.json` refuses a `budget` or `maxFiles` the matching flag would refuse.** `maxFiles: 0`
  was raised to 1 and a negative `budget` emptied the map, both silently; such a file is now
  reported as invalid by the rule the flag uses (`maxFiles: 0 is out of range; expected a positive
  integer`), like any other invalid config: named on stderr (and in `doctor`), and its defaults not
  applied.
- **`structural_search` over MCP reads as many files as every other area tool.** With no `maxFiles`
  in `.sextant.json` it read up to 8000 Swift files while the CLI and the other MCP tools read
  4000; it now reads 4000, and states the stop as before. The default lives in one place.
- **Through `sextant serve`, stdout and stderr keep the order the command wrote them in** when the
  caller's two streams are one file (one terminal, or `2>&1`): the daemon captured them apart and
  the client printed stdout first, so a warning that a direct run printed before the results came
  after them. Such a caller's streams are now captured as one, with stdout buffered as it would be
  in the caller's process. Callers whose streams go to different files are answered as before. An
  older client or daemon falls back to the previous behaviour.
- **`doctor` resolves a client command written as a bare name through `PATH`.** A `.mcp.json` or
  hook entry `sextant` was looked up as a file in the working directory and reported as "not an
  executable file"; it is now found the way a shell finds it and shown with the file it led to,
  with a note that a client started with another `PATH` may not find it.
- **`init --client claude-desktop` says when the registration it finds serves another project.**
  The machine-wide file holds one `sextant` entry, and "already registered" was printed whatever
  project that entry named; it now says `⚠ sextant is registered for claude-desktop with another
  project (…), not this one (--force to point it here)`, and does not tell you to restart the client.
- **`changed --help` no longer says "Swift only"**: it covers Objective-C, C and C++ with the flags
  from `sextant index`, as the MCP description already said.
- **Shell completion offers directories for `--derived-data`**, read from the kind each flag is
  declared with in the command catalog rather than from a list of its own.
- **The telemetry log is created readable by its owner only** (`0600`, as the adoption log already
  was): its entries name the queries asked. An existing file keeps its mode.
- **Releases.** The release workflow builds the fixture's index store and flags before the tests (it
  ran them without, so the C-family and semantic tests skipped themselves); refuses a tag that is
  not `vX.Y.Z[-suffix]` and passes every tag-derived value to the shell through the environment;
  and never replaces an archive already published — a repeat run completes a release that has no
  archive yet and fails on one that has, because a rebuild is not byte-identical and the published
  sha256 is already in the notes and the formula. CI runs with `contents: read`. (Unverified on
  GitHub Actions: checked for YAML syntax only.)

- **Breaking (`--json` schema, MCP answers): every column is 1-based and counted in UTF-16 code
  units.** That is the unit an LSP client uses by default, so a column can be handed to an editor
  as it is. Each source of positions used to report its own count of UTF-8 bytes — the index store
  for `refs`, `defs`, `callers`, `callees`, `impls`, `supertypes`, `hierarchy`, `context`, `blast`
  and `construct`; SwiftSyntax for `search` and `lint`; libclang for `search` and `lint` over
  Objective-C, C and C++; and the candidates of a stale answer — so on a line with Cyrillic or an
  emoji before the symbol every column was further right than an editor shows it (measured on
  `let привет = 1; let a = target(привет)`: 35 where an editor shows 29). They agreed with each
  other, and none was usable as an editor position. Now an emoji counts 2, a Cyrillic letter 1 and
  a tab 1, in text output, in `--json`, in the MCP `structural_search` and `lint` answers, and in
  everything an index-backed answer states. Lines are unchanged, and so is every column on a line
  that is ASCII up to the symbol. The index store's column is restated from the text of the line
  it was recorded on — the file as it is now, or, over a stale index, the text the store was built
  from; where that line cannot be read (a file gone, an indexed text that is unavailable, a line
  that no longer holds the column) a position states **no column**: `column` is absent from its
  JSON and the text shows `file:line`, never a column in another unit. `--help`, the command help
  and the MCP tool descriptions say how a position is written. The `search` and `lint` result
  caches move to a new version (`search-v4`, `lint-v4`); `sextant index` and `doctor` remove the old
  ones. Reading the line text costs nothing measurable: a warm `refs SwiftSources --project .` on
  this repository (release build, index fresh against its snapshot, median of 15 runs, wall clock
  including about 6 ms of the timing harness) took
  0.073 s before and 0.074 s after, `refs SourceLocation` (101 references in 21 files) 0.074 s
  both times — differences inside the run-to-run spread.

- **An index-backed query costs about 0.06 s instead of about 1.15 s.** Measured on this
  repository on the maintainer's machine (Apple silicon, release build, `refs SwiftSources
  --project .`, index fresh against its snapshot), by timestamps around each phase of one query:

  | phase | before, warm | after, warm |
  |---|---|---|
  | process start to `main` | 5 ms | 5 ms |
  | store location and selection, coverage (cached) | 85 ms | 11 ms |
  | finding libIndexStore (`xcrun --find swiftc`) | 77 ms | 3 ms |
  | freshness: git comparison with the snapshot | 178 ms | 16 ms |
  | freshness: toolchain (`xcrun --find swift`) | 82 ms | 3 ms |
  | opening IndexStoreDB | 728 ms | 8 ms |
  | query and rendering | 10 ms | 10 ms |
  | **wall time** (`/usr/bin/time`, 5 runs) | **1.14–1.16 s** | **0.05–0.06 s** |

  Through `sextant serve` the client waited 0.44–0.45 s and now waits 0.05–0.06 s; a second
  `find_references` call to `sextant mcp` took 365 ms and now takes 46 ms. A first query with
  nothing cached went from 1.36 s to 0.80 s — the one full import of the store (≈0.7 s) remains.
  Answers are byte-for-byte what they were (compared on this repository and the test fixture,
  text and `--json`, over a fresh and a stale index). Three things made the difference:
  - **Every helper process cost 65–70 ms more than it ran.** Waiting for a child with
    `Process.waitUntilExit` spins the run loop and returns tens of milliseconds after the child
    has exited; a query starts five or six helpers (`git`, `xcrun`). Helpers are now awaited on
    their termination.
  - **The IndexStoreDB database was imported from scratch on every command.** The database is
    kept between runs only when it is closed, and a command exited with it open, so the next one
    found no saved database and imported every unit again (≈0.7 s here). Commands now close their
    index before exiting. A kept database is used only while every unit it knew is still in the
    store: IndexStoreDB's import on open adds and re-reads units but never drops one that is
    gone, so a database that knew a vanished unit is removed and built anew.
  - **`sextant mcp` decided the stores twice per call** — once for the "has the index changed"
    signature and once for the trust label. It decides once, and both read that decision.
- **Input the tool does not understand is refused with a message naming it, never replaced by a
  default.** Each value-taking flag now declares in `CommandCatalog` what it takes — an integer
  with a minimum, one of a set, a path, or text — and every invocation is checked against that
  before the command runs or is forwarded to `sextant serve`, so the refusal is the same with a
  daemon and without one. **Behaviour change** — these used to run (exit 0, with the default in
  the place of the value) and now exit `2` with `sextant <command>: <flag> '<value>' …` on stderr:
  - a non-integer value of `--budget` (`map`, `api`), `--max-files` (`map`, `api`, `search`,
    `lint`), `--limit`, `--symbols` (`refs`, `defs`, `callers`), `--context-lines` (`body`),
    `--depth` (`hierarchy`) or `--iterations` (`bench`) — `--budget 8k`, `--max-files abc`;
  - zero or a negative number where it meant nothing and was quietly raised: `--budget`,
    `--max-files`, `--symbols`, `--depth` and `--iterations` below 1; `--limit` below 1 on
    `search`, `callees`, `impls`, `supertypes`, `context`, `body` and `construct`; `--limit` below
    0 on `refs`, `defs` and `callers` (where `--limit 0` still lists no positions and keeps the
    counts); `--context-lines` below 0;
  - `--store-policy` with anything but `recency`, `union` or `coverage` — it used to be dropped,
    and the store was chosen as if no policy had been given;
  - any value-taking flag given last, followed by another `--` flag, or given an empty value —
    `--project`, which fell back to `CLAUDE_PROJECT_DIR` or the current directory, `--from`, which
    fell back to `HEAD`, and every other one: `--scope`, `--exclude`, `--package`, `--type`, `--to`,
    `--rules`, `--spec`, `--scheme`, `--destination`, `--client`, `--index-store`, `--index-lib`,
    `--derived-data` and the numeric ones above (`golden` without a `--spec` value already
    refused). Every occurrence of a repeated flag is checked;
  - a non-empty `SEXTANT_STORE_POLICY` that is not a policy, for every command that takes
    `--store-policy` (the semantic commands, `mcp`, `serve`, `store`, `doctor`, `golden`, `bench`)
    unless `--store-policy` is given. It used to be ignored the same way; it is refused rather than
    warned about because a warning on stderr still answers from a store chosen without the policy
    meant, and an agent never sees stderr. An empty value still reads as unset.
  `init --client <unknown>` was already refused with exit 2 and still is, now by the same check.
- **The MCP server answers every line that is not a valid request, and validates tool calls
  against the declared input schemas.** Errors follow JSON-RPC 2.0 as MCP 2025-06-18 — the
  revision the server declares — narrows it. **Behaviour change** — these used to be dropped
  without a reply, or (marked †) processed as if they were valid:
  - a line that is not JSON → `-32700` Parse error, `id: null`;
  - JSON that is not a request object — a number, a string, `null`, and any array: MCP
    2025-06-18 removed JSON-RPC batching, so `[]` and a batch of requests are one `-32600`
    Invalid Request, `id: null`;
  - a request whose `id` is `null` (†, run as a notification), a boolean, a fraction or a
    structured value → `-32600`, `id: null`; one whose `jsonrpc` is missing or not `"2.0"` (†),
    whose `method` is missing or not a string, or whose `params` is not an object → `-32600`, with
    the request's `id`; `params` given as an array → `-32602`.
  A notification still gets no reply, and a response sent by the client is still ignored.
  In `tools/call`, each of these is now a `-32602` Invalid params protocol error, as MCP
  2025-06-18 classifies unknown tools and invalid arguments, instead of a tool result:
  - an undeclared tool, or no `name` — a result with `isError: true` and `unknown tool: …` before;
  - `arguments` that is not an object (†, read as no arguments);
  - a missing required `symbol` or `pattern` — `isError: true` and "the … parameter is required"
    before;
  - an argument of the wrong JSON type (†, the default used in its place): `depth` or `budget`
    that is not an integer (a string, a fraction, a boolean, `null`), and `symbol`, `pattern`,
    `package`, `type`, `scope`, `from`, `to` or `direction` that is not a string;
  - `direction` other than `callees` or `callers` (†, read as `callees`).
  The check reads the schemas in `MCPTools.definitions()`; none of them sets
  `additionalProperties`, so an argument a tool does not declare is still accepted. Tool names,
  input schemas and the `-32601` for an unknown method are unchanged.

### Fixed

- **`map --semantic` and `map --pagerank` dropped every `final` and `open` class.** The type name was
  read back from the rendered header, whose first word is now a modifier: `0	class class Square`
  where `refs Square` gives 3, and PageRank lost every edge into such a class. Both maps take the
  name and kind from the declaration itself (`RepoMap.publicTypes`); no other command re-reads a
  rendered header for a name.
- **After a failed `sextant index`, a source the build did not compile stays out of the index.** The
  snapshot is taken against the current text, so a file that never compiled read as unchanged and
  its uses vanished — no candidate, no `staleness`. The snapshot now records, after a failed build,
  the sources left without a unit for their present text (never compiled, compiled before they last
  changed, or reported with an error); freshness answers them as not indexed: positions unconfirmed,
  text matches listed as candidates, the files named — `2 file(s) it did not compile are not indexed:
  …`. Errors are also read from a build log the compiler coloured, which they were not.
- **`sextant index` stopped by SIGINT, SIGTERM or SIGHUP stops its build** — the build's process group
  and those of everything it started, through `Command` — and dies of the signal; the build used to
  keep rewriting the store. A run that does not finish leaves a marker, and while it stands every
  label says `the sextant index run started … did not finish — it is still building, or it was
  stopped — so the store may be partial` instead of `fresh`.
- **On the build-time basis, a source renamed or deleted after the build no longer reads as fresh.**
  Its positions were left out with `fresh (compared by build time)` and the use in the renamed file
  neither counted nor offered. A unit whose file is gone from a directory changed since the build
  makes the index stale (`1 source(s) the index was built from were deleted or renamed since: …`),
  and the store's uncovered sources in such directories are searched for candidates, as on the
  snapshot basis.
- **The coverage figure is no longer served from the cache for a different file set of the same
  size** — a rename kept the count and the old `7/7 (100%)`. The key is the file set itself; the
  cache moves to `store-coverage-v5`.
- **Missing toolchain pieces are named as what is missing**: a store with no libIndexStore to read it
  said `no index store found`; libclang's absence advised `--clang-lib`, a flag no command has; and a
  git that cannot run read as `the project is no longer in the git repository it was indexed in`
  instead of `git could not run (…)`.
- **An invalid `.sextant.json` written during an MCP session is said in every answer** (`⚠ config:
  …`), not only on stderr, which an agent never sees.
- **`search '$X <+> $Y'` folds by an operator the searched files declare** instead of refusing it as of
  unknown precedence; the same in `lint` rules and `structural_search`.
- **`defs` over a stale index counts each unconfirmed position once**: a definition that is also the
  answer's reference counted twice.
- **`map` text shows nested types at every depth** with their members, as `--json` does; it stopped
  at the second level.
- **`lint` and `search` over an area with no source** say `No source files here … — nothing was read`
  instead of `✅ No violations found` / `No matches.`.
- **`--scope /etc` is refused as outside the project**, not as a directory that does not exist.
- **The READMEs count 28 commands**, as the catalog does, and a test holds them to it.
- **`store show extra` is refused** like every other extra word: each subcommand declares how many
  arguments it takes (`show` none, `use` one) in `CommandCatalog`.
- **An umbrella index with a test target no longer advises dropping `--no-tests`**, a flag that was
  never passed and that an umbrella cannot act on: it says that a multi-package index builds the
  packages' library products, never their test targets, and that indexing the package on its own
  answers its tests. A single package whose tests were built is no longer told to drop the flag
  either.
- **`sextant store` under an explicit policy gives the reason for every store it does not read**
  (`not read: …`), in the words of the explanation every answer prints (`StoreSelection.reasonNotRead`).
  A `recency` tie is named as one rather than as "not the most recent".
- **`changed` reads a renamed C-family source with the flags of the path it was renamed from**, so a
  pure `git mv` of a `.cpp` is no change instead of "no compile flags — build the index", which could
  not help.
- **`changed` labels declarations of a public header `public`** — a header under `include/`, the
  same rule `api` uses (`IndexDeclarations.isPublicHeader`); they were `internal`, in text and
  `--json`. A C++ member declared private or protected there is labelled `private`.
- **A budget from `.sextant.json` is named as the config's**: `map` with a configured budget past the
  maximum said `--budget 9223372036854775807 is above the maximum…`; it now says
  `.sextant.json budget …`, and so do the MCP raised-minimum and lowered-maximum notes.
- **`--help` lists `version` once**, from the catalog; the hand-written "Other: version" line is gone.
- **`body --context-lines` sizes the line-number gutter from the lines shown**, not from the request:
  a huge value printed a 19-character gutter for an 81-line file.
- **A store that cannot be opened is not reported as missing**: with a read-only cache directory,
  `map` followed "could not open the index" with "no index store. Build one"; it now says the store
  could not be opened, or, with several stores and no policy, that a policy is needed.
- **`doctor` counts against the root only the C-family sources the root's build compiles.** A nested
  package's sources (this repository's `Tests/Fixtures/IndexFixture`, say) are named as that
  package's to index (`sextant index --project <it>`) rather than as "added since the last build?".
- **The trust label says why a snapshot was not used** when one exists and is not trusted:
  `compared by build time; snapshot not used: …`, in the words `sextant store` uses.
- **`index --app --derived-data <dir>` says that queries need the same location** (`--derived-data`
  or `SEXTANT_DERIVED_DATA`) when it is not Xcode's default; a plain query looked in the default one
  and found no store.
- **Copies of an index database IndexStoreDB has discarded are removed when it is opened** — by its
  own rule (`…-dead`, or `p<pid>-…` of a process that has exited). It removes them on a background
  queue a short command never lets finish, so concurrent cold queries left ~28 MB copies behind until
  the next `index` or `doctor`.

- **No Swift rule matches every node of a C++ file.** After clang's twenty-error limit the probes of
  later patterns raised no error, and the recovered `$X` alone matched everything — `lint` reported
  46 `force-unwrap` violations in the fixture's C++ file. Every error is now reported, a pattern that
  is a bare metavariable is refused for the C family too, and clang's paths are compared with the
  project's whatever their spelling (`/tmp` and `/private/tmp`), which also kept the probes' errors
  apart from the file's ("read with reservations" for a file that builds).
- **`api` reads a C++ header a source includes**, also in a project under a symlinked path; it was
  left out as "no compiled source includes this header".
- **Through `sextant serve`, output on one file is cut where a direct run cuts it.** The daemon
  buffered standard output in 1024 bytes instead of the caller's block size, so a warning landed in
  the middle of a line of `map`, `api`, `lint`.
- **`search --json` and `lint --json` state a `--max-files` cut on stderr**, as `map --json` and
  `api --json` do; the JSON shape is unchanged.
- **`doctor` before the first `index` of a new version no longer deletes the only copy of the
  compile flags** (an old-format `compile-db/<root>.json` whose project has no new entry yet); it
  says the next `sextant index` carries them over.
- **A file deleted with its whole directory, in an umbrella, is marked `[unconfirmed: file deleted
  since indexing]`** and shown relative to the project, without the contradictory "out of date
  despite the marker above" note.
- **A source deleted but not committed is not listed** for `search`, `lint`, `doctor`, `index` and
  coverage, where it was "could not be read (permissions?)" or "has no flags".
- **The compile-flags warning clears after `sextant index`.** A successful index that recompiled no
  C-family file now confirms the kept flags, so only a build made some other way is named.
- **`sextant store` names the stores it sets aside**, not the one it reads, and a coverage tie says
  so instead of "covers less (5 files against 5)".
- **Smaller:** stale `refs --json` candidates are spelled like the index's paths (`/private/tmp`),
  and an unconfirmed position is not listed again as a candidate; `--scope` naming a file says it
  is not a directory; `store use` leaves a read-only `.sextant.json` alone (exit 1); `doctor` names a
  `SEXTANT_CACHE_MAX` that is not a number; `changed` ignores untracked files in hidden directories
  (`.build/`); `body --context-lines` with a huge value no longer crashes.
- **`doctor --fix` reports a failed index build.** It ran the build and discarded the result, so a
  build that failed over an older store ended in "✅ ready"; it now prints `❌ doctor --fix: the
  index build failed (exit N)` and exits 1.
- **The compile flags a failed build printed are kept.** Under SwiftPM's Swift Build system the
  flags are read from the build's output, and a file prints them only when it compiles: a first
  `sextant index` that failed on a Swift error after the C files compiled stored nothing, and the
  next, successful and incremental, run compiled nothing and asked for `swift package clean`. A
  failed build now stores the flags it printed (merged with what was known, as a successful one
  does), and says so.
- **A `.sextant.json` edited during an MCP session decides the stores of the very next call.** The
  config was forgotten only inside `tools/call`, after the call's stores had been chosen with the
  old store policy, so a policy written mid-session took effect one call late (and never for
  `resources/read` or completion). It is now forgotten at the start of every message.
- **`list_implementations` no longer calls a declared-only symbol unknown.** A C function declared in
  a header and defined nowhere the index saw was "symbol not found" there, while `who_defines`
  showed it; it now answers "no implementations found" for it, and "symbol not found" only for a
  name the index has no record of.
- **`lint --rules` names the error of the shape the file has.** A rules array with `pattern` instead
  of `patterns` was reported as "Expected to decode Dictionary<String, Any> but found an array
  instead" — the error of the object form; it now says that the key `patterns` is missing.
- **A transient `accept()` error no longer stops `sextant serve`.** An interrupted call, a
  connection the client dropped before it was accepted, or a moment without free descriptors
  (`EINTR`, `ECONNABORTED`, `EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`) ended the serving loop and the
  daemon; they are now waited out. A closed listener still ends it.
- **`sextant mcp` closes its index database at the end of input every time.** The session's index
  was also held by the signal handlers, which are released on their queue whenever that runs, so
  the process could exit with the database still open — the next command then imported the whole
  store again. Seen as an intermittent failure of `CleanStopTests` under load.
- **Tests.** The test process runs with a home of its own (`CFFIXED_USER_HOME` under `/tmp`, set
  before any test; `Tests/TestHome`), so no test writes into the real `~/Library/Caches/sextant`
  any more; `make ci` runs the binary with `.build/fixture-home`, which the test home starts from.
  Tests that returned early, and passed, when their throwaway package did not build now fail; the
  ones that need something absent are skipped with the reason. `make ci` runs `golden`, as CI
  does. Redundant `#require` warnings are gone.

- **A source deleted before a build no longer stays in answers under a label that says "fresh".**
  A build does not remove the unit of a deleted file from its store, so `callers target` after
  deleting a caller's file and running `sextant index` still counted and listed the file, with
  the trust label `fresh (compared against the snapshot …)`. Two changes:
  - `sextant index`, after a successful build of its own tree (`.build/sextant-index`, or the
    umbrella in the cache), removes from that store the units whose source file no longer exists —
    the units only, never their records, never a unit for SDK code or a module, never a store
    anything else writes — before it records the snapshot, and says which sources it removed them
    for. A renamed or moved file loses the unit of its old path.
  - Every symbol answer (`refs`, `defs`, `callers`, `callees`, `impls`, `supertypes`, `hierarchy`,
    `context`, `blast`, `construct`, `body` and their MCP tools) leaves out a position the index
    records in a file under the project root that no longer exists — the symbol, the reference or
    the call it belongs to — so the text and `--json` totals do not count it, and names what it left
    out: on stderr in the CLI (text and `--json` alike, beside the trust label), in the answer itself
    in MCP (`⚠ left out of this answer: N position(s) in M file(s) the index still records but that
    no longer exist — …`). This is what applies to a store sextant does not build (DerivedData, a
    plain `.build`, `--index-store`), which keeps such units. A file outside the project root (an
    SDK, a toolchain) is not judged; a file the stale-index layer already reports as deleted since
    indexing keeps its `[unconfirmed: file deleted since indexing]` marking, with no second
    statement. **Output changes** only where a position lay in a missing file; everywhere else it
    is byte-for-byte what it was.
- **A reused IndexStoreDB database no longer answers from a unit rewritten under its old
  modification time.** IndexStoreDB re-reads a unit on open only when its modification time moved,
  so a unit rewritten with its time put back (a restored backup, `touch -r`, a build that keeps
  times) left a kept database answering from the unit as it was — measured: a removed function was
  still found. The record a database keeps of its units (`sextant-units`) now holds each unit's
  modification time (to the nanosecond, as IndexStoreDB compares it), size, inode and status change
  time, and the database is built anew when a unit has the recorded modification time but a
  different size, inode or status change time, as before when a recorded unit is gone. A unit
  rewritten in place under the same modification time, size, inode and status change time is not
  told apart — writing a file moves its status change time, so that takes a clock set back or a
  file system that does not keep that time. A record in the earlier format (unit names only) has
  the database built anew once. Units a long-lived process (`serve`, `mcp`) imported while open are
  added to the record when it closes, so their later removal is noticed too. The check is a
  directory listing plus one `lstat` per unit, and the record is written only when it changes: a
  warm `refs SwiftSources --project .` on this repository takes 0.06–0.07 s as before; measured
  alone (release build), the check costs 1.7 ms against 1.3 ms on this repository's 578 units, and
  32 ms against 20 ms on a synthetic store of 10 000 units.
- **`sextant serve` and `sextant mcp` keep their index database when stopped by a signal.** A daemon
  stopped by SIGTERM or Ctrl-C left its database open under a per-process name, and the next command
  imported the whole store again; `sextant mcp` was killed outright by SIGTERM and SIGINT. Both now
  handle SIGINT, SIGTERM and SIGHUP on a dispatch queue (not in signal context): once the request in
  progress is answered they close the index — the daemon also removes its socket, as before — and
  exit with 0. The end of input already closed the index in `mcp`.
- **The umbrella and the compile database of a deep or oddly named project are kept.** Their cache
  entries were named by the project root with `/` replaced by `_`, the defect the IndexStoreDB
  database had: a deep root failed with "File name too long", and `/a_b/c` and `/a/b_c` shared one
  entry. `umbrella/` and `compile-db/` entries are now named by a hash of the canonical root and
  record the root they belong to; a compile database is `compile-db/<hash>/compile_commands.json`,
  and the flags of the roots around and inside a root are found by the roots the entries record.
  Queries never read entries under the old names. **Once after upgrading**, the first
  `sextant index` of a project carries its flags over: when the project's new entry has none and
  the file of the old naming for exactly that root exists, its commands (less those for files that
  are gone) become the new entry, which keeps the old file's write time — the time the flags were
  captured, which the staleness note judges by — and `sextant index` says so in one line; the build
  that follows merges its own capture over them, and the cache eviction then removes the old file.
  Where there is no old file for that root (it was never indexed, or the old file is already gone),
  the flags are captured from the build as for a new project: an umbrella is rebuilt from scratch,
  a single package's flags are read from the build graph where SwiftPM's native build system writes
  one, and where they come only from what the build prints (SwiftPM's Swift Build system, Xcode) an
  incremental build prints none, and `sextant index` says so and asks for a clean build
  (`swift package clean`, `xcodebuild clean`) before it runs again.
- **Robustness of the index layer.**
  - **A helper that hangs no longer hangs the query, and no helper reads the caller's input.**
    `git`, `xcrun` and `swift --version` are run with the null device as stdin (a helper reading
    stdin could swallow the MCP client's requests or a hook's payload, or wait on a terminal) and
    with a timeout of seconds (30 s for `git`, 15 s for asking the toolchain); the build `sextant
    index` runs keeps no timeout. A helper that runs out of time is killed and is a named failure
    the caller handles as it handles a failed one — freshness then says the comparison could not
    be made — instead of an empty success, which is what a timed-out helper returned before.
  - **The IndexStoreDB database of a deep or oddly named store opens.** Its directory was the
    store path with `/` replaced by `_`: a store deeper than about 250 characters failed with
    "File name too long", and two stores such as `…/a_b/store` and `…/a/b_store` shared one
    database. It is now named by a hash of the canonical store path. Databases under the old names
    are never read again and are removed by the cache eviction below.
  - **The cache directory no longer grows without bound.** `sextant index` and `sextant doctor`
    now remove from `~/Library/Caches/sextant` the versions of a cache a newer format replaced
    (`declarations-v3`/`v4` beside `v5`, `lint-v1`/`v2`, `search-v1`/`v2`, `store-coverage-v2`,
    …), the IndexStoreDB databases, index snapshots, borrowed git directories, umbrella packages
    and compile databases of stores and projects that no longer exist, the copies of indexed text
    no snapshot refers to, and sockets no daemon holds, and say how much they removed. On the
    machine this was written on, the first run removed 2 985 entries, 3.96 GB, of which the
    IndexStoreDB databases alone had taken 3.7 GB. Nothing outside the cache directory is removed,
    and a symbolic link in it is removed as a link.
    `SEXTANT_CACHE_MAX` (default 10 000 files) bounds each cache namespace in use, as before; the
    other directories are pruned by whether what they belong to still exists.
  - **`map --pagerank` gives the same bytes on every run.** The scores were summed in hash-table
    order, which differs between runs: measured, the `--json` scores differed in their last digits
    on every run and the text order changed in one run of six. The sums now run in sorted order
    and equal scores rank by path; `map --semantic` breaks a tie of name by file. **Output changes
    once**: scores may differ in their last digits from what an earlier version printed.
  - **libIndexStore and libclang are found under a toolchain whose path contains `/bin`
    elsewhere.** The library directory was made by replacing every `/bin` in the tool's path with
    `/lib`, which turned `/Users/bin-tools/…/usr/bin/swiftc` into `/Users/lib-tools/…`. It is now
    the `lib` beside the tool's own `bin` directory.
  - **Through `sextant serve`, freshness compares against the caller's toolchain.** The toolchain
    an index is checked against came from the daemon's `PATH` and `DEVELOPER_DIR`, so the same
    query was `fresh` on its own and "built with one compiler, now another" through a daemon
    started from another shell. `PATH`, `DEVELOPER_DIR` and `TOOLCHAINS` now travel with the
    request like `SEXTANT_STORE_POLICY` does.
  - **`context` counts every callee.** It printed `calls: 10` for a symbol that calls thirty
    functions — the count of the sample it showed. It now counts all of them and says
    `… (first 10 of 30 callees shown)`. The `--json` shape is unchanged; its `callees` list is the
    sample, as before.
  - **The compile-flags warning judges the flags the answer reads.** It looked only at the
    database stored for the exact root, while lookups also read the databases of the roots around
    it and inside it, so it stayed silent about stale flags read from a containing root. It now
    judges every database the answer reads, by the oldest of them.
  - **The umbrella store is chosen by the selection, not before it.** The freshest store across
    the umbrella's layouts and configurations was picked outside `StoreSelection.resolve`. Every
    store in the tree is now a candidate, and the selection keeps, of each build tree only
    `sextant index` writes — the umbrella, or a package's own index tree — the store it wrote
    last, naming the others as left over from earlier runs. **Behaviour change** for a package
    whose own index tree holds stores of both build systems' layouts: the one written last
    answers, where a policy was asked for before.
- **Which stores and files an index answer is drawn from.**
  - **A project under a directory named `checkouts`, or one that itself lives under a `.build`
    directory, keeps its own sources.** Every occurrence whose path contained `/checkouts/` or
    `/.build/` anywhere was dropped, so such a project answered every symbol question with
    nothing. A build tree is now recognised in the part of the path below the project root (any
    `.build` directory there), and Xcode's dependency checkouts by `SourcePackages/checkouts`; a
    source directory that happens to be named `checkouts` is a source directory. **Answers change**
    for such projects: they now find the project's own symbols.
  - **A store whose `units` directory is empty is not a candidate.** It used to count as usable
    in the locators, the selection, `doctor` and `sextant store` — and a store named with
    `--index-store` was labelled `fresh` — because the directory's own time was read as the time
    the store was built. It is now set aside as "no units — nothing to read", and its freshness is
    `unknown`. **A project whose only other store was such an empty one** now answers from the
    remaining store instead of refusing for want of a policy.
  - **An explicit store policy sees every candidate.** The "configuration built last" filter ran
    before the policy and could remove the store the policy would have chosen (a debug store that
    covers more, under `coverage`; both configurations under `union`). It now runs only when no
    policy is set. **Answers change** under `coverage` and `union` where a package has both debug
    and release stores.
  - **The umbrella store takes part in the decision instead of hiding every other store.** For a
    project of several packages, the store `sextant index` builds in the cache used to be the only
    candidate whenever it existed — fresher stores and stores covering files it does not were never
    listed. It is now a candidate beside the project's own stores and counts as a store `sextant
    index` built: with no policy set it answers by the same rule as a package's own index tree, and
    the others are listed as set aside by that rule; with an explicit policy it is weighed against
    them. `sextant store` lists all of them (`found by:` names every source) and says which
    answers; the provenance label names the source of the store that answered. **Answers change**
    for multi-package projects with an explicit store policy, which may now choose another store.
  - **`sextant index --app` reports the store its build wrote**, found among the candidates by the
    container it built, and warns when several usable stores now need a policy — through the same
    selection every command uses, instead of a second routine that took the freshest DataStore.
  - **Coverage is no longer served from another project's measurement.** The coverage cache was
    keyed by the store and the file count only, so one store measured against two projects with as
    many files (or with and without tests) gave the first number for both. The key now includes the
    canonical project root and whether tests count (cache namespace `store-coverage-v3`).
  - **One project spelled two ways has one umbrella.** The umbrella directory and its build log
    were keyed by the raw `--project` string, so `--project .` wrote `umbrella/./swift-build.log`
    and a relative and an absolute spelling built two umbrellas. They are keyed by the canonical
    root now; an umbrella built under a non-canonical spelling is not found again — run
    `sextant index` once.
  - **Compile flags are found from any root that contains the file.** Flags are stored under the
    root `sextant index` was run for and were looked up only under exactly that root, so the
    C-family files of a nested package indexed on its own (this repository's fixture, in its own
    self-lint) showed "no compile flags" from the root around it. Lookups now read the database of
    the root, of every root containing it and of every root inside it, keeping the entries for
    files under the root asked about. **`lint`, `search`, `api`, `map` and `doctor` change** where
    such databases exist: those files are now checked. Both spellings of a `/tmp` path already
    shared one key — that half of the report was not reproducible.
  - **`lint` names the pattern when no rule could run in a C-family file.** A file in which every
    rule pattern failed to compile was reported as "no rule could be checked here: error: use of
    undeclared identifier 'Calendar'" — the first pattern's diagnostic, read as a fault of the
    file. It now says that no rule pattern compiles as Objective-C, C or C++ there and names the
    first pattern with its diagnostic.
- **What an answer leaves out.**
  - **A symbol of the name with no definition in the index is answered beside the defined ones.**
    `refs`, `defs`, `callers` and every command built on them dropped a symbol whose recorded
    occurrence is a declaration (a C function a header declares, an Objective-C protocol) or a use
    of an external symbol whenever another symbol of the same name had a definition; only when none
    had one were they all answered. They are now added beside the defined ones, and where defined
    and undefined symbols share an answer the undefined one says `def: not in the index (an external
    symbol, or one only declared here)`. **Answers change**: more hits for such names.
  - **No more silent cap of 1000.** CLI `impls` and `callees` counted and listed at most 1000
    related symbols, `construct` counted construction sites among the first 1000 references,
    `blast` listed at most 1000 implementations, and `--verify` compared the textual count against
    the capped list. They now count from the real totals; the text list still stops at `--limit`
    and says how many more there are, and `impls`/`callees --json` keeps its array shape with a
    "first N of M shown" note on stderr when `--limit` cut it. **Answers change** above 1000.
  - **MCP `resources/read` carries the trust label** a tool answer carries (`sextant://symbol/{name}`,
    and `sextant://repo_map` when an index is open): which store, how fresh, on what basis.
  - **Advice on refreshing a stale index names what refreshes it.** "Rebuild the project or run
    `sextant index`" was printed whatever wrote the store, and an ordinary build does not refresh a
    store `sextant index` built in a tree of its own. The advice in the provenance label, `doctor`,
    the withheld-snippet and vanished-file notes, `body`'s "could not extract" and the textual
    fallback now comes from one place that knows the writer: `run sextant index` for a store it
    built (its own tree or the umbrella), rebuilding the project for Xcode's index, and both for a
    store whose writer cannot be told.
- **Not changed, on purpose: a changed file `.sextant.json` excludes still makes the index stale.**
  Index answers are not narrowed by `exclude` — an excluded file's positions are in them — so
  leaving it out of the changed files would leave those positions unmapped and unmarked over a
  stale index.

- **`search` and `lint` name what they could not really check instead of passing it off as "checked,
  no matches".**
  - **A pattern the matcher could not bind is refused.** **Behaviour change** — each of these used
    to answer "No matches." (exit 0; in MCP a successful empty answer) and is now a usage error
    naming the reason (exit `2`; an error result in MCP; a rule with one is reported broken by
    `lint`): a metavariable inside a string literal (`"$X"`, `"$$$"`); a pattern of several
    statements (`foo(); bar()` used to match `foo()` alone and ignore the rest); a metavariable in
    a comment; a second `$$$` in one list (`f($$$, $$$)`); and any other metavariable the matcher
    never reaches as a hole — found by walking the pattern the way matching does, not from a list
    of cases. For Objective-C, C and C++ a pattern clang compiles with a metavariable outside an
    expression position (`@selector($M)`, which used to report "No matches.") or with several
    statements (only the last was matched) is refused for each file with the reason, so with no
    Swift reading either the command exits `2`.
  - **Other inputs that now mean something different.** **Behaviour change**: a Swift pattern
    with an operator whose precedence is not a standard one (`$X |> $Y`) is a usage error naming
    the operator — it used to match only a flat sequence of exactly that shape; and `$F(a:)` (a
    metavariable with argument labels) binds only the base name and compares the labels — it used
    to be a hole for any whole expression, labels ignored.
  - **MCP `structural_search` refuses a pattern that is not Swift when no C-family file could be
    searched with it**, as the CLI already did. **Behaviour change**: it used to return a
    successful answer listing the unsearched files.
  - **A Swift file that cannot be read, or is not UTF-8, is listed as not scanned**, with the
    reason; it used to be skipped without a word, in `search`, `lint` and MCP `structural_search`.
  - **A file read through errors is named.** A Swift file with syntax errors, and a C-family file
    clang reports errors in (it used to count as scanned), is still searched — its matches are
    kept — and listed under `⚠ read with reservations`, since a match in it may be missing or
    wrong. `--json` of `search` and `lint` gains `readWithReservations`.
  - **Directories the walk skips are named when they hold sources** — `vendor`, `build`, `Pods`,
    `Carthage`, `node_modules`, `checkouts`, `DerivedData` and checked-out submodules from
    `.gitmodules` — as not scanned, with how to search them (`--scope`). Which directories are
    walked has not changed. In `--json` they are `notScanned` entries whose `file` ends in `/`.
  - **`lint` lists headers as not scanned**, as `search` does: what a header contains is never
    matched, only a translation unit's own code.
  - **`lint`'s check for broken patterns knows both languages.** It compiled every pattern as Swift
    only, so a valid Objective-C rule was reported broken and a C-family pattern that never compiled
    was not. A pattern is now broken when Swift rejects it and clang either refuses it or compiled
    it in none of the files it tried; the reason names both halves, and says so when no C-family
    file was checked with it.
- **The C-family matcher tells operators apart.** `!$X` matched `-x`, and any unary operator any
  other, since the operator was not compared; prefix and postfix `++` were one shape too. The
  operator is now compared for unary, binary and compound-assignment expressions (libclang's
  operator kind, or the source text where the toolchain lacks it).
- **`body` (and MCP `body`) finds a declaration with an attribute on the line above it**
  (`@MainActor` or `@objc` on a line of its own): the index records the line of the name, and the
  declaration was looked for only where its attribute starts.
- **A bare name in `exclude` takes a directory of that name, at any depth.** `--exclude vendor`
  excluded only a file named `vendor`, which nobody has, and so nothing. A pattern without `/`
  now matches any path component, gitignore-like, and a trailing `/` (`Generated/`) keeps it to
  directories; the README states the rule. **Behaviour change**: a bare-name pattern now also
  excludes directories of that name (`Legacy*` excludes `LegacyKit/…`, which it used to keep).
- **A Swift operator pattern matches inside a larger expression.** SwiftParser leaves
  `y = value as! Int` as one flat sequence, so `$X as! $T`, `$X + 1`, `$X ?? $Y`, `$X == nil`,
  `$A = $B` and a ternary matched nothing inside an assignment, a longer chain of operators or
  `try? a ?? b`, and said "No matches." Both the pattern and the searched file are now folded with
  the precedence the compiler uses (`a + b * c` is `a + (b * c)`: `$X * $Y` matches `b * c`, and
  `$X + $Y` matches the whole with `$Y` bound to `b * c`). Operators declared in the searched
  files are folded with their declared precedence. An expression with an operator whose
  precedence is still unknown is not folded on a guess: it is compared as written, the rest of
  the file matches as usual, and the file is listed under `⚠ read with reservations` naming the
  operator. On this repository `$X == nil` finds 56
  instead of 40 and `$X ?? $Y` 319 instead of 271, every earlier match position still among them;
  `try? $X` finds the same 124, of which 10 now show the whole expression the `try?` covers
  (`try? x as? T`), as the compiler reads it.
- Per-file result caches move to `search-v3` and `lint-v3`, since a cached result now also records
  whether the file had syntax errors or an expression that could not be folded, and results
  themselves change with folding.

- **`api` left out part of the public surface, and `changed` stayed quiet about changes to it.**
  An omission there is a wrong answer, not a shorter one. Each of these is now read and compared:
  - **A property with a restricted setter was taken for private.** `private(set) public var x`,
    `internal(set) public var`, a bare `private(set) var` — the setter's modifier was read as the
    declaration's access level, so a public property vanished from `api`. The getter's level
    decides now, and the setter's restriction is part of the signature
    (`private(set) var x: Int`), so narrowing it is a change.
  - **Text `api` printed two levels of nesting and no conformance-only extension.** A public type
    nested inside a nested type, and its members, were missing from the text while `--json`
    carried them; `extension Foo: Equatable {}` was missing from both. Every level is printed now,
    and a conformance is listed — unless the files declare the extended type, or every protocol in
    it, without making it public. On this repository: 924 → 1124 declarations in the text, the
    same 1124 as `--json` (which gains the two conformances).
  - **Two `extension Foo` blocks, or overloads, were compared as one key.** Changes inside the
    second block were missed or attributed to the first. Declarations sharing a name are now
    matched by identical signature (among identical blocks, by the members they share), then by
    argument labels when that is unambiguous, then by shared members; only what is left is
    reported as added or removed.
  - **Parts of the contract were not in the compared signature**, so changing them read as "no
    change": attributes (`@available`, `@discardableResult`, `@MainActor`, `@objc`, `@frozen`, …,
    compared as a set, so reordering is not a change; optimisation hints such as `@inline` are
    left out); a typealias's right-hand side; a property's or subscript's accessors (`{ get }`
    against `{ get set }`, with their effects — observers and bodies are not part of it, and a
    stored property shows none); `open` against `public`; `final`, `required`, `convenience`,
    `mutating`, `nonisolated` and the other modifiers that change what a caller may do; `where`
    on an initializer or subscript; an enum case's raw value; and `associatedtype` and `macro`
    declarations, which were not extracted at all. A `deinit` stays out: nothing can call it.
  - **A type whose header changed hid the changes to its members.** Its members are compared
    whatever happened to the header.
  - **A case under `#if` lost its condition** (and its attributes and doc summary) when the enum's
    access was given to it, and a case list re-wrapped across lines (`case a, b` → two lines) read
    as a change. Cases are compared one by one, each with its condition.
  - **Objective-C, C and C++:** declarations inside `extern "C" { … }` and Objective-C class
    extensions (`@interface Foo ()`) were dropped; a header written over several lines
    (`@interface Foo : Base <P1,` / `P2>`, a method's keywords) was cut at the first newline. A
    C-family file renamed in the range was read at its new path in the old revision, so all of it
    looked added; it is read at its previous path, as Swift files already were. A change under a
    preprocessor branch the build does not compile is invisible to clang: the file is now named as
    compared only in part, with the lines.

  **Visible changes in output** (`--json` only gains keys and values; no key changes meaning):
  - headers carry more of the signature, in `api`, `changed` and `map` alike —
    `var share: Double?` → `var share: Double? { get }`, `class ClangLibrary` →
    `final class ClangLibrary`,
    `typealias T` → `typealias T = Int`, ``case `private` `` → ``case `private` = 0``;
  - in `changed`, an `open` declaration reads `open class A`, no longer `public class A`;
  - `api` and `changed` list declarations they used to miss (above), and enum cases carry their
    doc summaries;
  - `api --json`: every declaration gains a `name` key, and `kind` can be `associatedtype` or
    `macro`;
  - `changed --json` gains `partiallyDiffed` (`[{file, reason}]`), and the text and the `changed`
    MCP tool add `⚠ compared in part (N) — code the build does not compile changed:` with one line
    per file;
  - members of a type whose header changed are listed after it, and output with equal names is
    ordered by header, so it no longer varies between runs.

  The declaration caches move to new namespaces (`declarations-v5`, `drift-declarations-v2`), so
  nothing extracted under the old rules is read as current.

- **`--reindex --json` printed the build's progress into the JSON, and a failed rebuild answered
  from the old index.** With `--json` the progress of the rebuild now goes to stderr and stdout
  carries the JSON document alone. A rebuild that fails ends the command with exit `1` — what
  `sextant index` returns for a failed build — and `--reindex failed — not answering from the
  index that was there before the rebuild` on stderr, instead of an exit `0` answer from a store
  marked as coming from a failed build. **Behaviour change** for scripts that ran
  `--reindex` against a project that does not build: they now see exit `1`.

- **Positions in a file edited since indexing could be dropped as macro duplicates.** The check
  that drops a second position a macro records on one line read the file as it is now at the
  columns the index recorded for the old text, and could drop a real reference that had merely
  moved. It now reads the text the positions were recorded in.

- **`sextant index` found no index on a toolchain whose SwiftPM defaults to the Swift Build
  system (Swift 6.4).** That build system writes the store to
  `.build/out/Products/<Configuration>/index/store`, and only `.build/<triple>/<configuration>/index/store`
  was looked for — so a build that had succeeded was reported as `build failed (code 0)`. Both
  layouts are read now, for a package and for the umbrella alike, and a build that succeeds
  without leaving a store is said to have done exactly that.
- **Objective-C, C and C++ had no compile flags under the Swift Build system.** It writes no
  build graph with arguments in it, so the flags are read from the verbose output of the build
  `sextant index` runs. Its output therefore goes to a log, whose path is printed, instead of the
  terminal. A build that compiles nothing states no flags, so flags captured earlier are kept.
- **`sextant index` left no store, or a partial one, in a package that had been built before.**
  Under the Swift Build system a package already built without an index store counts as up to
  date when built with one: nothing compiles, no store is written, and the C-family flags are
  never printed. Where only some files recompiled, the store covered those alone and was still
  reported as `index ready`. `sextant index` now builds a package in a tree of its own,
  `.build/sextant-index`, which nothing else builds and which is always built with the index
  store on, on either build system — whatever was built before, the store covers every file that
  compiles. The cost: a second build tree on disk beside `.build`, the dependencies fetched into it
  once more, and a full build the first time. `swift package clean` removes it with the rest. Its
  store is found beside the ordinary ones, so where an ordinary build also wrote a store (the
  native build system does by default) there are two; with no store policy set, the one
  `sextant index` built answers (see Changed). An ordinary `swift build`
  does not refresh this store — `sextant index` (or `--reindex`) does, and the stale-index hint
  now says that.
- **Over MCP, "the 10 most used" symbols sharing a name were the first ten by USR.** The cut
  relied on an order only the CLI produced. The answer now orders the symbols itself, so every
  surface keeps the most used, and the usages of the symbols left out are counted from the
  index's own totals rather than from lists stopped at the internal cap.
- **MCP `body` could return another declaration's body.** After an edit moved a file, it printed
  whatever declaration started on the line the index recorded, as a successful answer. It now
  checks the name the way `sextant body` does — both go through one code path — and a body that
  cannot be extracted is an error result.
- **MCP answers cut without saying so.** `lint` printed 200 violations, the C-family half of
  `structural_search` 200 matches, `list_implementations` 1000 entries and `call_hierarchy` 40
  children per node, with nothing to show that more existed; the Swift half of
  `structural_search` said "first 200 shown" while printing more. Every cut now states what it
  left out and the true total, and `sextant hierarchy` says the same per node in its text output.
  The `--json` shapes are unchanged.
- **`blast` presented the internal cap as the total.** A symbol with 4 000 usages was reported
  with 1 000, and its affected files were taken from those first 1 000 locations only. Counts and
  files are totals now, in `blast`, `blast --json` and MCP `blast_radius`. When several symbols
  share the name, the text output says how many were added together.
- **The `sextant://repo_map` MCP resource answered differently from the `repo_map` tool.** It
  read no index and dropped the notes on files past `maxFiles` and on non-Swift files left out of
  the map. Both now produce the same answer through one code path; the resource's default budget
  is the tool's (4 000 tokens, or `budget` from `.sextant.json`).
- **With `sextant serve` running, some commands answered differently or not at all.** The
  daemon refused a short list of commands and answered every other one, so `hook` read the
  daemon's stdin and recorded nothing, `completion` failed on the `--project` the client adds,
  and `store use` wrote its policy from inside the daemon. The daemon now answers only the
  read-only queries the command catalog marks as such; a command added later runs in the client
  until it is marked.
- **A command run through the daemon read the daemon's surroundings, not the caller's.** A
  relative `--rules`, `--index-store`, `--index-lib` or `--derived-data` was opened in the
  daemon's working directory, and `SEXTANT_STORE_POLICY` and `SEXTANT_DERIVED_DATA` came from
  the daemon's environment — so a daemon started with one store policy answered every client with
  it. `context` printed its compact form on a terminal, because the daemon's output is a pipe.
  Paths are now made absolute by the client, and the caller's values of those variables and of
  "is the output a terminal" travel with the request and are the ones in force.
- **A project reached through a symlink was refused by its own daemon, with exit 2.** The socket
  was named after the resolved path, but the request was compared with the daemon's own spelling.
  Both sides now use one canonical root. A daemon that declines a command, or one left running
  from another version, no longer answers in the command's place: the client runs it itself.

## [0.9.1] — 2026-11-04

### Added

- **A measurement history** — [docs/measurements/history.md](docs/measurements/history.md) keeps
  every benchmark row each release published, with what produced it, so the numbers can be
  followed across releases. The benchmark pages now show 0.9.1, re-measured on the same commits.
  Doing it turned up that the 0.9.0 figures for scenario A could not be reproduced with the 0.9.0
  binary that was released (swift-nio 5 055 declarations published against 4 259 printed); both
  are kept, and the release procedure now re-measures and names the binary rather than only
  bumping the version on the page. The recipes were re-run: with test targets in the index,
  `blast`, `context` and `impls` count the tests too.
- **A Claude Code plugin, distributed from this repository.** `/plugin marketplace add
  RSafargalin/sextant` then `/plugin install sextant@sextant` registers the MCP server for every
  project opened, a skill that says when to ask the index instead of grepping, and a
  `/sextant:setup` command that runs `doctor` and offers to build an index. The wiring drops from
  four manual steps to one; the binary is still Homebrew's job, and the launcher says so by name
  instead of failing silently. It registers no hooks: the adoption hook writes from the moment it
  is installed, which keeps it a decision for `hook --install` rather than a side effect of an
  install.
- **`body --context-lines N`** — N lines on each side of the declaration, numbered, with the
  declaration itself marked apart from its surroundings. Measured on another tool of the same shape:
  18.4 % of symbol queries were followed by a plain read of the same file, and in four fifths of
  those the body had already been delivered — the agent held the declaration and was reaching for
  what sits around it.
- **A follow-up count in `sextant adoption`** — how many of our answers were followed *next* by
  opening a file. A share says how often the tool was reached for; this says whether the answer was
  enough. It measures adjacency, not the same file, and says so.
- **`sextant doctor` checks the wiring, not only itself** — the MCP registration and the adoption
  hook: whether the binary each names exists, and whether the hook has ever recorded anything. Every
  check before this was about the tool's own process, which is how a hook that was registered
  nowhere passed a green check-up for ten days.

### Changed

- **A store `sextant index` built answers ahead of the stores an ordinary build left.** Nothing but
  `sextant index` writes `.build/sextant-index`, so its store is the one whose contents are known.
  A package holding both used to refuse every semantic question until a store policy was set; with
  no policy set, the store `sextant index` built is now read and the others are named as set aside.
  An explicit policy — `--store-policy`, `SEXTANT_STORE_POLICY`, `storePolicy` in `.sextant.json` —
  still decides, and stores of ordinary builds are still chosen between by a policy when there is
  no store `sextant index` built. The rule is printed by `sextant store` and named in the
  provenance line whenever it made the choice.
- **Freshness of a store `sextant index` built is judged by content, against a snapshot taken when
  it was built.** At the end of a build `sextant index` records the sources it built from (in git:
  the `HEAD` commit and the content of every source that differed from it; outside git: every
  source), the store's unit file names and timestamp, the toolchain, the hashes of `Package.swift`
  and `Package.resolved`, the build's exit status and whether tests were built. It lives in
  `~/Library/Caches/sextant/index-snapshot/`, never in the project. A query then compares content:
  the label says how many files changed since the index was built and names up to three of them,
  names a changed manifest or toolchain as reasons of their own, and says when the index came from
  a build that failed or left out tests. Every other store — Xcode's, an ordinary build's, one named
  with `--index-store`, or one rewritten since its snapshot — is still judged by build time, and
  every label now says which basis it used (`compared against the snapshot taken by
  \`sextant index\`` or `compared by build time`). The check costs more than the old one: measured
  on this repository (debug build, in process), 16 ms per query on a clean tree against 8.4 ms, more
  when files are modified — two `git` processes and a toolchain lookup in
  place of a `stat` of every source. `--json` outputs are unchanged.

### Fixed

- **A touch, or a branch switched away and back, made a fresh index `STALE`.**
  Freshness compared modification times, so any of these marked an index built from exactly the
  current sources as stale. For a store `sextant index` built it is now a comparison of content,
  and they change nothing.
- **A release build made after `sextant index` pushed its store out.** Only the configuration built
  last took part in the choice, and that filter ran before anything else — so a later
  `swift build -c release` set the debug store `sextant index` built aside as "another
  configuration". The filter now runs after the rule above.

- **The adoption metric counts what a command runs, not the words in it.** A shell line is split
  into the commands it actually runs. `sextant` counts only when it runs a navigation command —
  not `--help`, `hook` or `index`, and not a path such as `cd ~/Tools/sextant`, which made up 239 of
  640 "calls" in two months of the first log. A search tool counts only when it searches files —
  first in its pipeline, fed by `xargs` or `find -exec`, or reading the sources or a list of them
  through a pipe; `swift build | grep error` filters a build log, and such lines were 28 % of what
  was counted as text search. A search limited to files other than sources — `grep -n X docs/a.md`,
  `rg -g '*.md'`, the `Grep` tool with `glob: "*.md"`, `Glob` of `**/*.md` — is not counted, the way
  a `Read` of a README never was; a target held in a variable set in the same line is judged by its
  value. A call counts every kind of act it ran, once each: `sextant search X | head; grep -rn X
  Sources` is an answer and a search, and the answer is marked as cross-checked — in real sessions
  about a fifth to a quarter of the lines asking sextant also grepped the sources. An act made
  about another project — after a `cd` there, or a sextant call with `--project` there — is not
  counted for this one; the live log records it under the project it was about. `lint` is not counted as navigation:
  it judges the code rather than finding anything in it.
  Commands inside `for`, `if` and `{ }` count; heredoc bodies and
  comments do not; `git grep` counts. A source file printed with `cat`, `sed -n`, `head` or `tail`
  is a read, the same act as the `Read` tool — before, those reads were missing from the
  denominator. The pattern of a search is found past `--type swift`, `-j 4`, `--exclude-dir X` and
  `--`, which used to be reported as the pattern. MCP tools of a plugin-bundled server
  (`mcp__plugin_sextant_sextant__…`) were not recognised at all and now are.
- **The live log keys a project by its repository.** Every worktree and subdirectory of a
  repository is one project; before, each directory a session stood in was its own. Lines carry
  `"v": 2`, the client's session and subagent identifiers, and `via` (`mcp` or `cli`) for a
  sextant answer. Lines of the first format are not added to the new ones: `sextant adoption`
  names how many it left out.
- **`sextant adoption`** reads the whole repository: transcripts of its worktrees and
  subdirectories, admitted by the directory each session stood in, and the transcripts of
  subagents, workflow agents included. It splits answers into MCP and CLI, counts live sessions,
  finds a read after an answer only within one session and agent, and reports from the live log
  alone when the client kept no transcripts. It names how many answers were cross-checked by a
  search in the same call. `--json` gains `transcripts`, `throughMCP`, `throughCLI`,
  `readAfterSextant`, `crossCheckedAnswers` and a `live` object; no field was removed.
- **`sextant index` says when the store it just built holds none of the project's tests.** The
  SwiftPM path builds them; the Xcode path cannot be fixed the same way, and this is measured rather
  than assumed: `xcodebuild build-for-testing` builds the test targets and writes **no index store at
  all** — twice on Alamofire's own project under Xcode 26, where a plain `build` of the same scheme
  wrote one. What works is the scheme: with a test target in its Build action, a plain build covers
  87 of 98 files and answers 504 references where the scheme's default covers 43 and answers 25. So
  the build now measures its own result and names the remedy instead of leaving a partial index to be
  discovered in an answer. The same check on the SwiftPM path points at `--no-tests`.
- **A build that indexed nothing says why.** An incremental Xcode build compiles nothing, so it
  writes no index units, and `index --app` reported `build succeeded, but no DerivedData index was
  found` with nothing about the cause. It now names it: `xcodebuild clean`, then build again.
- **`sextant index` builds the test targets, and an answer that misses them says so.** The build ran
  `swift build --enable-index-store` without `--build-tests`, so no usage written in a test existed
  for any semantic command. Measured on Alamofire at `0455bfb`: the store covered 43 of 98 files and
  `refs Session` answered **25**; with the test targets built it covers 87 of 98 and answers **504 in
  33 files** — the same 504 sourcekit-lsp reports once its own index has caught up. An earlier
  measurement recorded the two tools as agreeing at 25; they agreed because both were partial at that
  moment. The build costs about twice as long (44s against 80s there), paid once per build against an
  undercount paid on every query; `--no-tests` opts out, and the coverage line now names the test
  files a store was not built from.
- **A name shared by hundreds of symbols is answered, not dumped.** `callers request` on Alamofire
  printed 337 symbol blocks — an answer whose size is the reason this tool exists. The ten most used
  are printed now, and the rest are stated: how many symbols were left out and how many usages they
  hold between them, with `--symbols N` for more and `--json` for all of them. MCP is capped the
  same way and offers no advice on narrowing, because there is no way to name one of several symbols
  that share a name — a gap this makes visible instead of papering over.
- **A store an editor keeps for itself is named as one.** Installing the `swift-lsp` plugin gives
  every project a second index store under `.build/index-build`, and the comparison that asks for a
  store policy showed two interchangeable-looking paths. Each candidate that belongs to sourcekit-lsp
  or to Xcode now says so. The choice is still the reader's — see
  [ADR-0006](docs/adr/0006-store-policy-is-a-persons-decision.md), where the editor's store held more
  units and covered half as many files.
- **`ugrep` and `bfs` are counted as the searches they are.** A client that routes `Grep` and `Glob`
  through the shell as those binaries was invisible to the adoption denominator. One list now serves
  both the hook and the transcript reader, and the test walks the whole list.
- **A store with units but no records is named, not blamed on the symbol.** Such a store resolves
  nothing while dating itself as fresh, and the answer explained it as "does not resolve semantically
  (a closure, a local, or another kind of symbol)" — a confident diagnosis of the wrong thing.
- **A daemon stopped by SIGINT or SIGTERM removes its socket.** Ownership was already held by an
  flock, so an orphan blocked nothing, but a socket file outliving its process claims a listener that
  is not there.
- **The MCP handshake answers with the revision this build implements**, instead of echoing whatever
  the client asked for — which turned every client's guess, including revisions published after the
  binary was compiled, into confirmation.

## [0.9.0] — 2026-08-17

An answer now says what it stands on. Which index store it came from and how much of the project
that store covers; whether a number is the whole count or the part that fit; where a symbol is
defined as opposed to where it is called. The work started as one bug — the wrong store was chosen
on a project with agent worktrees, so every semantic answer was empty under a `fresh` label — and
turned into a pass over every place the tool answered confidently without being able to. Forty
defects were reproduced by running the tool, written down as tests that fail when they are fixed,
and closed. Six public repositories and the reference project were used to check that they stay
closed.

### Added

- **`sextant store` and an explicit store policy.** A project routinely has more than one index
  store — `swift build` writes one, an editor's indexer another, a second checkout its own — and
  they answer the same question differently: measured on this repository, 83 references from one
  and 34 from another, 91 from both merged. So the tool no longer chooses. With one usable store
  nothing is asked; with several and no policy, semantic commands refuse and print what each policy
  gives, what it does not and what it costs. `store use recency|union|coverage` records the choice
  in `.sextant.json`; `--store-policy` overrides it for one command, `SEXTANT_STORE_POLICY` for one
  machine. Whenever there was a choice, every answer carries the line that says how many candidates
  there were, which are being read and why the others were not
  ([ADR-0006](docs/adr/0006-store-policy-is-a-persons-decision.md)).

- **Coverage of the opened store, in the trust label.** `[index: derivedData · 1 store(s) · fresh ·
  covers 10337/12351 files (84%)]`. Freshness is about time, coverage is about extent, and a fresh
  store can hold half a project: a release build compiles no test target, so every reference from a
  test is missing from a store nothing else marked as partial. Measured on this repository, the same
  query against two stores of one project: `covers 92%` → 74 usages in 23 files, `covers 55%` → 46
  in 17. It is read from the units, cached against the store's own state, and costs nothing on every
  run but the first after a build.

- **A units reader for libIndexStore** (`CIndexStoreShim`, `dlopen` over a declared subset of the
  ABI, as the libclang layer already does). IndexStoreDB answers about symbols and cannot tell "this
  store does not cover the file" from "the file has no such symbol"; a unit answers directly — this
  is the file it was built from. It is what makes the `coverage` policy and the label above possible.

- **`api --budget <tokens>`** bounds the printed surface and the header then states what was left
  out. There is no default: a public surface is a contract, and cutting one silently changes what
  every existing answer says. Over MCP the budget does have a default — an agent reads the answer
  into a context window.

- **`--derived-data` and `SEXTANT_DERIVED_DATA`.** The DerivedData location was hard-coded, so a
  project built with `xcodebuild -derivedDataPath ./build` — which every CI does — looked like a
  project with no index at all.

- `index` now states what it runs and what holds it back, and it says something different for each
  path, because the two are not equally protected. Measured with a hostile manifest and a hostile
  build plugin: SwiftPM sandboxes both — no network, no writes into your home directory — but they
  can read it; `--app` runs `Run Script` phases with your full access and no sandbox at all. Both
  notices name `--no-build`, which indexes an already-built project and runs nothing. Three MCP
  tool descriptions sent an agent to run `sextant index` without ever saying it builds the project;
  they say it now. Wrapping the build in `sandbox-exec` was measured and is impossible — SwiftPM
  applies its own sandbox and a nested one is denied by the kernel.

- `init --client <name>` registers the MCP server for a client other than Claude Code. The list is
  `claude-code` (default, a file in the project) and `claude-desktop` (one list per machine, so the
  project is named in the arguments). Everything the `.mcp.json` path was already careful about now
  holds for every client: other servers in the file survive, a file that does not parse or whose
  servers key is not an object is left alone rather than repaired, already-registered is reported
  rather than treated as an error, and the entry carries the absolute path to the running binary.
  The client name is validated before anything is written, so a typo does not leave half a setup
  behind. Closes [#7](https://github.com/RSafargalin/sextant/issues/7).

- `exclude` in `.sextant.json` and a repeatable `--exclude` flag: globs for files that are tracked
  on purpose and still have no business in an answer — generated code, vendored sources, snapshot
  fixtures. `--scope` could only narrow to one subtree; it cannot subtract. The filter sits after
  both discovery paths, so a git project and a non-git one leave out exactly the same files, and
  the syntax is a small predictable part of glob (`*`, `**`, a bare name at any depth) rather than
  a subset of gitignore — a partial gitignore is unpredictable, and unpredictable exclusions hide
  code without the user knowing. Closes [#9](https://github.com/RSafargalin/sextant/issues/9).

- [docs/recipes.md](docs/recipes.md) — twelve questions and the commands that answer them, with
  real output: is this type safe to delete, who calls this through the protocol, what changed on
  this branch symbol by symbol. Everything shown was produced by running the command against
  Alamofire at `0455bfb`, which the page names so a reader can reproduce it, and re-running them
  is now a step in the release checklist — documentation that drifts silently is worse than none.
  Closes [#6](https://github.com/RSafargalin/sextant/issues/6).

- `completion zsh` and `completion bash` print a completion script, generated from the command
  catalog — the same data that builds the help and validates flags, so a command added later
  cannot silently fall out of completion. Flags are offered per command rather than as one flat
  list, a flag that takes a value expects one instead of suggesting the next flag, and `--project`,
  `--scope` and `--index-store` complete directories while `--rules` and `--spec` complete files.
  Closes [#2](https://github.com/RSafargalin/sextant/issues/2).

### Fixed

- **The wrong index store was chosen on a project with nested worktrees, and every semantic answer
  was empty.** An agent worktree lives inside the checkout, so its DerivedData passed the "inside
  the project" test, and being rebuilt more recently it also won on freshness — after which the
  record filter rejected every path in it as foreign. On the reference project `refs
  AbsAccountsViewModel` returned nothing and explained it as "a closure, a local, or another kind of
  symbol" about a class; it now returns the definition and 7 usages in 3 files. Selection applies the
  same scope predicate the filter applies; where a foreign store is used anyway, the empty answer
  names it instead of inventing a reason.

- **A call hierarchy pointed at call sites and called them definitions.** `timestamp(ofStore:)` was
  shown at line 48 — where it is called — while it is defined at line 25, and nothing said which of
  the two it meant. The definition is now resolved by USR, the call site is a separate field, and a
  symbol the index has no definition for is marked rather than given a made-up position.

- **A reference written inside a macro was counted twice.** A macro records the reference at its own
  position as well as at the real column, so every count over code wrapped in `#expect`/`#require`
  came out high: 81 against 74 occurrences of the name on this repository. A position whose column
  does not carry the symbol's name is dropped when another position on the same line does; a lone
  unverified position is kept, because the name may be written in a form the check cannot see.

- **`api --json` served internal members of public types.** The visibility filter was applied to the
  top level only, so the text answer dropped them and the machine contract carried them — one
  question, two answers. Found on Alamofire.

- **Counts stopped presenting a part as the whole.** `construct` counted one position twice when a
  line held two constructions; `--limit` rewrote the header count instead of shortening the list;
  the internal cap of 1000 references was printed as the total and is now named (`1000 of 1265`).

- **Structural search and lint.** A pattern the parser only recovered from (an unbalanced bracket)
  answered `No matches.` with exit 0 and now fails with the reason — while a pattern that is not
  Swift but is valid Objective-C still goes to clang. `search --limit` was accepted and ignored.
  An exclusion that removed every result is now named. A `lint` rule whose pattern never compiled
  was counted in the header as if it had run.

- **`changed`** now sees a symbol leaving the public surface (the access level is part of the
  compared signature), follows a renamed file instead of reporting a rewrite, and refuses to diff a
  file that does not parse — a recovery tree reported the half it dropped as deleted symbols, which
  is exactly the state an agent's half-finished edit leaves behind.

- **Freshness and staleness.** The freshness signal walked `*.swift` only, so an edit to a `.m` or a
  header left the label saying `fresh`. An answer that points at a deleted file now says so — a
  deletion moves no timestamp, so the marker cannot see it. A snippet is withheld when the recorded
  line no longer carries the symbol, instead of printing whatever text now sits there.

- **Compile flags had no notion of time.** They are captured by `sextant index`; every other build
  moves the index forward and leaves them behind, and a `-DFEATURE=1` that has since become `0`
  yields a structural match inside code the current build does not contain. A build newer than the
  capture is now named, with the gap. Entries for files that no longer exist are dropped when the
  database is read — measured on this machine, two databases held 75 of 75 and 72 of 73 such entries.

- **`--verify` was silent in the two directions that matter.** More semantic hits than textual ones
  cannot be true of a name written where it is used, and it printed the pair without comment. Fewer
  semantic than textual, with the difference sitting inside `#if` branches this build does not
  contain, fell exactly on the wrong side of a ×3 threshold (the measured case was 1 against 3);
  those lines are now counted and named.

- **`--project` pointed at a directory containing several projects borrowed a foreign index.** A path
  prefix is not a project boundary: `--project ~` offered the store of an unrelated app from
  `Downloads`, covering 6% of what it called "this project". The boundary is the checkout.

- **The MCP surface.** Answers carry the provenance line the CLI prints — a client logs stderr at
  best, so the agent, the main consumer, never saw where an answer came from. `repo_map` gets the
  index the CLI gets and names the non-Swift files missing without it. `list_implementations`
  distinguishes an unknown symbol from one without implementations. Area tools are bounded by
  `maxFiles` and say what they did not read. The store policy refusal reaches the answer instead of
  the log. A `.sextant.json` edited while the server runs takes effect on the next call.

- **Smaller refusals that used to pass silently:** an empty symbol, a single-dash flag spelling
  (`-project`), a `--project` that does not exist, an unmatched `api --package`, a misspelled key or
  policy value in `.sextant.json`. The daemon re-reads the file list per request instead of freezing
  it for its lifetime. A package is addressed by the name in its manifest rather than by the first
  path component, so a project that keeps packages outside `Packages/` can address them at all.

- **The daemon's output capture could hang, and did hang CI.** Draining ran as a block on the
  global queue while the caller was already blocked on the write, so anything holding the pool's
  threads — several `Process.waitUntilExit` calls, say — starved the reader that would have
  unblocked it. Reproduced with 80 blocked tasks: the write never returned, and a watchdog on the
  same queue never fired either. Each reader now gets a thread of its own. The test written for the
  original defect passed locally in 0.002s and timed out at 60 seconds on the runner, twice; the
  starvation itself is now a test.

- **The clang layer counted a file nobody could open as scanned**, and a byte that is not valid
  UTF-8 shifted every offset after it, so a column and a snippet were both wrong while presented as
  structural.

### Changed

These are the stability contract — CLI flags, JSON schemas, MCP tool names, exit codes — and this
release breaks some of it, which is why the minor version moves.

- **Exit codes.** Cases that used to answer 0 now fail: an unparsable structural pattern, an empty
  symbol, a single-dash flag, a `--project` that does not exist, an `api --package` that matches
  nothing. Semantic commands exit non-zero when several index stores are usable and no policy is
  set.

- **`--max-files` degrades instead of refusing.** `map`, `api`, `search` and `lint` used to answer
  "more files than the limit" and nothing else; they now read the limit and name what they did not
  (`⚠ covered 4000 of 12351 file(s)`), which changes their exit code on a large project from 1 to 0.
  The bound is a prefix of the file list in a fixed order, so two runs cover the same files.

- **`--json` shapes.** `refs`/`defs`/`callers` return an object rather than an empty array when the
  semantic answer is empty and the textual degradation applies, so a consumer cannot read textual
  matches as resolved ones. `blast`, `hierarchy` and `context` return `{"symbol": …, "found": false}`
  for an unknown symbol where they used to print prose on stdout. `lint --json` carries
  `brokenRules`; `map`/`api` summaries carry the package name from the manifest.

- **Interface Builder is documented as out of scope.** `.storyboard` and `.xib` are not read and not
  planned; a class named only from a nib is invisible. Measured on the reference project: 376 classes
  are bound from nibs and none of them lives only there, so the cost is an undercount in impact
  analysis rather than a false "nobody uses this"
  ([ADR-0007](docs/adr/0007-no-interface-builder.md)).

- **Benchmarks re-measured** for scenarios A and B at the same pinned commits. Every surface is
  larger than at 0.7.0 (Alamofire 973 → 1 226 declarations) because declarations behind `#if` and
  internal extensions carrying public members are now part of the surface; the saving band moves
  from 79–91% to 79–90%.

- A shared IndexStoreDB directory between processes was recorded as a defect and is not one:
  measured, per-process databases are worse at every level of concurrency (4 processes: 34.4s shared
  against 73.8s separate), answers never diverged, and nothing indicated a re-import or corruption.
  The stand is in [docs/measurements](docs/measurements).

## [0.8.1] — 2026-08-07

### Added

- `doctor` reports when `PATH` holds more than one `sextant`, naming which one a shell would run
  and which one is speaking. The two documented install routes land in different directories, and
  a copy from `make install` in `~/.local/bin` usually comes first — so `brew upgrade` succeeds
  while the tool keeps answering with the old version, and nothing points at why.

## [0.8.0] — 2026-08-07

The C family stops being a blind spot. `search`, `lint`, `changed`, `api` and `construct` now
read Objective-C, C and C++ as well as Swift — through clang, with the exact flags each file was
built with, captured from the build. Where an answer cannot cover something, it says so: files
without flags, patterns that do not compile there, and code inside `#if` branches the build does
not contain are all named rather than passed over. `adoption` measures how much of an agent's
code navigation goes through the tool at all.

### Added

- `adoption` — the share of code navigation that went through sextant instead of past it, and,
  more usefully, what went past: the searches an agent ran as text, grouped by the shape of the
  query. An identifier searched with grep is a question `defs` or `refs` answers exactly, so each
  one is either a gap in the tool or a gap in how it describes itself. The share alone would be a
  scoreboard; the residue is what there is to fix.

  The denominator cannot come from sextant — the searches that went elsewhere are invisible to
  it — so it is read from the client's own session transcripts. Only two fields of a record are
  ever looked at, the tool's name and its query, and the query is reduced to a shape immediately:
  no pattern, path or message text is kept or printed unless `--show-queries` asks for it, and
  nothing is sent anywhere.
- `hook` — the same signal live, for a client's `PreToolUse` hook: one line per navigation act
  carrying a timestamp, a hash of the project root, the act and the shape of the query. Not the
  query, not the command, not the path. `sextant hook --install` prints how to install it and
  exactly what it writes; it is off until someone does. Beyond measurement it is the point where a
  later version can offer the answer instead of counting the grep.

- `changed` diffs Objective-C, C and C++ at the symbol level, not just Swift. A past revision has
  no build of its own, but it does not need one: its text is parsed against the flags the file is
  compiled with today, which measures clean. A file with no flags at all, or a revision that does
  not parse, is named with the reason instead of being counted as unchanged.
- `lint` runs its rules over Objective-C, C and C++ as well, reading each file once for all of
  them. A rule written for another language simply does not compile there, which is not a gap; a
  file where **no** rule could run is reported, because nothing about it was checked.
- `api` reports the public surface of C++ headers. They used to come from the index, which lists a
  header's free functions and drops every class — a surface that looks complete and is not,
  because the index carries no access level. A header with any C++ in it is now read through
  clang, private and protected members excluded, using the flags of a translation unit that
  includes it; a header no compiled source includes is named rather than shown as empty. The MCP
  `api` tool answers the same as the CLI, which it did not before: it was never given the index,
  so through MCP the surface was Swift-only.
- `search` reads Objective-C, C and C++ through clang, so a structural pattern is no longer a
  Swift-only question: `sextant search '[$X reloadData]'` finds message sends the way
  `try? $X.save()` finds Swift calls. The pattern is compiled inside each file, appended to it in
  memory, because that is the only place its selectors are known — compiled on its own, an
  Objective-C pattern comes back from clang with an empty selector under ARC. Whatever cannot be
  read is named with its reason (no flags, the pattern does not compile here, a header is not a
  compilation unit), never counted as "no matches".
- Occurrences inside `#if` branches the build does not contain are reported too, as a separate,
  textual tier. clang runs the preprocessor, so such code never reaches the tree and cannot be
  matched structurally — on SDWebImage a search finds 15 usages where grep counts 28, the other
  13 sitting under `#if SD_UIKIT` on a macOS build. Reporting only 15 would leave an agent about
  to change that API to break another platform; merging them would pass a textual guess off as a
  verified match. So both are given, labelled and separate: `15 matches` plus `⚠ 13 more textual
  occurrence(s) inside #if branches not built for x86_64-apple-macosx10.13 — found by text, NOT
  structurally verified`. `--json` carries them in `inactiveOccurrences`. `lint` does the same,
  reporting a rule that matches textually there as a possible violation.

  Swift is not affected and stays broader than the build: SwiftSyntax does not evaluate `#if`, so
  a Swift search covers every branch, including `#if false`. The asymmetry is deliberate — clang
  cannot build a tree without running the preprocessor, and an extra hit sits in plain sight next
  to its `#if` while a silent omission does not.
- A compile database: `index` records the exact flags each Objective-C, C and C++ file was built
  with, and `doctor` reports whether every such source is covered. This is the groundwork for
  reading those files structurally ([ADR-0004](docs/adr/0004-structural-layer-for-c-family.md)):
  clang builds a complete AST only with per-file flags, and roughly a third of one with guessed
  flags — so the flags have to come from the build, and a file without them will be refused rather
  than answered for. They are read from the build graph SwiftPM writes (`.build/<configuration>.yaml`),
  where each clang node carries its arguments as a JSON array, rather than scraped from build
  output: an incremental build that compiles nothing prints nothing, while the graph still
  describes every file. Xcode writes no such graph — its own manifest lists compile nodes without
  their arguments — so there the flags are read from the build log, where the full clang
  invocation is printed, shell-escaped and behind a response file. Because an incremental build
  compiles nothing and therefore prints nothing, a capture merges into what was already known
  rather than replacing it: a project built one scheme at a time would otherwise keep losing the
  flags of everything else.
- Objective-C, C and C++ across the semantic commands. The index store is written by the whole
  clang family, so this needed symbol resolution to be fixed rather than a parser to be added:
  selectors (`greetWithName:`) are now matched, and a symbol declared in a header now resolves
  to its definition in the implementation file.
- `map` and `api` cover the same languages, reading Objective-C and C declarations from the
  index; C++ headers go through clang instead (see above), because the index carries no access
  level.
- `body` extracts C, C++ and Objective-C declarations. It previously answered for Swift only,
  and a C++ struct that happened to parse as Swift came back missing its trailing `;`.
- A four-language fixture (Swift, Objective-C, C, C++) with an Objective-C protocol and its
  conformers, and brace traps inside strings, character literals and comments.
- [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md): the structural layer for the
  C family will be built on libclang, not tree-sitter, with the measurements behind that.
- `golden` accepts `callees` assertions. The command shipped without regression cover in the
  spec that exists to provide it.
- Fixture cover for C++ overloads, an uninstantiated template, a nested namespace and an
  Objective-C category. All four already worked; overloads resolve to separate USRs, so callers
  of one signature are not attributed to the other.

### Changed

- The rule sets no longer drift. `--rules` **replaces** the built-in set, as it always did, and now
  says so in the output; a file may instead be an object with `"extends": "builtin"` to add to
  them, which is the answer to "the defaults plus two of mine" that previously meant copying the
  defaults by hand and losing them at the next release. Every `lint` answer states which set it
  used, because "no violations" from two rules is not the claim it is from five.
- The built-in set is documented as **a starting point, not a safe default for every project** —
  there is no universal set: `print-call` is wrong for a command-line tool and `force-unwrap` is
  noise in interop-heavy code. sextant's own `sextant-rules.json` takes two of them and leaves the
  rest deliberately, which is why its CI never applied `print-call` and nothing said so.
  Closes [#5](https://github.com/RSafargalin/sextant/issues/5).

- **Breaking (`--json` schema):** `search --json` returns `{"matches": [...], "notScanned": [...]}`
  and `lint --json` returns `{"violations": [...], "notScanned": [...]}`, each in place of a bare
  array. Every `notScanned` entry is `{"file": ..., "reason": ...}` — a file left out, and why.
- `search` and `lint` name the non-Swift files they skipped, in the text output, in `--json` and
  in the MCP answer. Both commands walk `.swift` only, so on a project with Objective-C sources
  they used to report "No matches." and "✅ No violations found" about files they had not read —
  a clean bill of health covering unexamined code. The tool descriptions say so too, because an
  agent never sees stderr. Actually reading those files is [ADR-0004](docs/adr/0004-structural-layer-for-c-family.md) work.
- **Breaking (`--json` schema):** `changed --json` returns an object
  `{"files": [...], "notDiffed": [...]}` instead of a bare array; the former array is now the
  `files` field. Each `notDiffed` entry is `{"file": ..., "reason": ...}`.
- `changed` names the C, C++ and Objective-C files it could not compare. It used to drop them, so
  a commit touching only `.m` files reported "no symbol-level changes" — a confident wrong
  answer of exactly the kind this tool exists to prevent.

### Fixed

- `.gitignore` is now honoured in full for a project that is **not** under git. The fallback read
  only bare directory names from it, dropping every line with a `/` or a `*` — so `Generated/**`,
  `[Dd]ebug/` and `Sources/*/Legacy` did nothing, and those files landed in `map`, `api`, `search`
  and `lint`. Rather than growing a subset of gitignore — attempted in
  [#8](https://github.com/RSafargalin/sextant/pull/8), and unpredictable, because a partial
  implementation fails silently — git itself is borrowed: the project becomes a work tree whose
  git dir lives in the cache, so negation, bracket classes, nested `.gitignore` files and
  "last matching pattern wins" all behave exactly as git defines them, and nothing is written
  inside the project. Closes [#3](https://github.com/RSafargalin/sextant/issues/3).

- Conditional compilation no longer makes declarations vanish quietly. `api` and `map` dropped
  everything inside a `#if` — an iOS-only public method was simply absent from the surface on a
  Mac, with nothing said about it. Those declarations are now listed with the condition that
  guards them (`func onlyOnPhone()  [#if os(iOS)]`), and `changed` treats moving a declaration
  under a condition as the API change it is. The declaration cache version was bumped, since its
  key is the file's content and the extraction itself changed.
- A symbol that resolves to nothing now says why when the reason is knowable. "Does not resolve
  semantically (a closure, a local, or another kind of symbol)" was misleading for a symbol that
  exists only inside a `#if` branch this build does not contain — the answer now says exactly
  that, and marks which occurrences are conditional.
- The textual fallback searches Objective-C, C and C++ as well. It walked `.swift` files only, so
  an unresolved Objective-C symbol degraded to a search that never opened a `.m` file and
  reported nothing at all.
- `api` and `map` state when non-Swift files use `#if`: their declarations come from the index,
  which holds one configuration, so a branch that configuration does not contain is not in the
  answer. Swift declarations under `#if` are listed with their condition instead of counted.

- `construct` looked for the Swift shape `Type(` in every language, so on an Objective-C project
  it found nothing at all — which reads as "nothing constructs this type" rather than "this
  command cannot see it". Objective-C creates objects by sending `alloc` or `new` to the class,
  and that is what is looked for there now. A substring match also counted `makeStore(` as
  constructing `Store`; a shape now has to start at a word boundary.
- Index store selection used the store directory's own modification date, which does not change
  when units are rewritten inside it. A stale store could win over a fresh one and the semantic
  commands would answer from it — silently, and wrongly. All three selection sites now use the
  same freshness layer.
- `map` printed two messages about one missing index.
- `callees` counted call sites as callees: a method called twice on one line was reported as two.
  Results are now grouped per symbol, with the extra sites listed under it. `hierarchy` showed the
  same child twice for the same reason, and the duplicate also consumed its breadth budget.

## [0.7.0] — 2026-08-05

First public release.

### Added

- Repository documentation for public use: `README`, `CONTRIBUTING`, `SECURITY`,
  `CODE_OF_CONDUCT`, `AGENTS.md`, issue and pull request templates. Documents written for
  people ship in English and Russian (`*.ru.md`).
- `docs/benchmarks.md` — reproducible measurements on five public Swift packages at pinned
  commits, with the commands to re-run them.
- A regression test for index store selection across build configurations.

### Changed

- Renamed the project from its working title to **sextant**. This touches everything a user
  sees: the binary, the config file (`.sextant.json`), the rules file, the MCP server name,
  the URL scheme, the cache directory (`~/Library/Caches/sextant`) and the
  `SEXTANT_NO_DAEMON` environment variable. There is no migration path from the old names —
  the tool had no public release under them.
- CLI help, MCP tool descriptions, error messages and code comments are now in English.
- `sextant help` shows the build timestamp next to the version, so two builds of the same
  version are distinguishable in the field. `sextant --version` still prints the bare version
  string — it is machine-readable and checked by the release workflow.
- CI and the release workflow run on the `macos-26` runner and select the newest available
  Xcode, failing loudly if the toolchain is older than Swift 6.2.

### Fixed

- **`body` works across the C family.** It parsed every file with SwiftParser, which silently
  mis-handled anything that was not Swift: an Objective-C `@implementation` returned nothing at
  all, so did a C function, and a C++ struct happened to parse as Swift and came back missing its
  trailing `;`. Non-Swift declarations are now delimited instead of parsed — the index already
  gives the exact definition line, so only the end has to be found. Objective-C containers run to
  `@end`, prototypes stop at their semicolon, and braces inside strings, character literals and
  comments are skipped rather than counted.
- **`api` reports the public surface of Objective-C and C targets.** In SwiftPM a target's
  public headers live in `include/`, which is the module map's own answer to what the target
  exposes — so this is the layout's definition of public, not a guess. C++ headers are
  deliberately refused: they declare private members alongside public ones and the index carries
  no access level, so listing them would present private members as public API. `api` says how
  many it left out rather than returning a surface that looks complete.
- **`map` covers Objective-C, C and C++.** Non-Swift files are read from the compiler index
  rather than through a second parser, so the repository map shows the whole project instead of
  its Swift half. A declaration repeated in a header and its implementation is listed once;
  one that exists only in a header is kept, since that is the only place it appears. When such
  files exist but no index has been built, the map says how many it could not read instead of
  quietly omitting them. Swift is still parsed with SwiftSyntax — the index carries no
  visibility information, and the map filters on access level — so a pure-Swift project takes
  exactly the path it did before, with no index required.
- **Semantic commands now resolve Objective-C symbols.** The index store is written by the
  whole clang family, not just swiftc, so Objective-C, C and C++ declarations were always in
  it — but two defects kept them out of reach. Objective-C methods that take arguments are
  stored as selectors (`greetWithName:`), which matched neither an exact name nor Swift's
  `name(` shape, so a bare method name resolved to nothing. And a symbol whose canonical
  occurrence is a header declaration — the norm in Objective-C and C — reported no definition
  at all, because the definition in the `.m` or `.c` was only ever collected as a reference.
  Both are fixed, so `refs`, `defs`, `callers`, `context` and the rest work across a language
  boundary: a Swift call spelled `greet(withName:)` is found as a caller of the Objective-C
  selector it actually calls. C and C++ needed no change; they already worked.

- **Semantic queries went blind on projects that had ever been built in release
  configuration.** The index store was selected by the modification time of the store
  *directory*, but a build rewrites unit files *inside* the store without touching that
  directory. A one-off `swift build -c release` therefore left a small, stale release store
  looking permanently "newer" than the debug store that regular builds keep current. On a
  real project this meant a 110-unit store was chosen over a 2203-unit one: `defs` found only
  test-target symbols, `impls` returned nothing for a protocol with a conforming actor in the
  same file, and every query was labelled `⚠ STALE` immediately after a successful `index`.
  Store selection now uses the same units-based freshness signal as the rest of the tool, in
  all three places that select a store (SPM packages, umbrella build, Xcode DerivedData). A
  store with no units is no longer a candidate at all.
- **`sextant init` wrote a non-existent binary path into `.mcp.json`.** When sextant was
  launched through `PATH`, `argv[0]` is the bare name `sextant`, which was resolved relative
  to the current directory — producing `<project>/sextant`. The launch path now comes from
  the kernel, so the registration points at the real binary. The stable `bin/` symlink is
  still preserved rather than resolved, so `brew upgrade` does not break the registration.

## Earlier versions

Developed privately up to 0.6.x; see `docs/roadmap.md` for the iteration history and the
gates each one had to pass. Those versions were never published, so no compatibility is
claimed for them.
