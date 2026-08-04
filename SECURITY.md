# Security Policy

**English** | [Русский](SECURITY.ru.md)

## Reporting a vulnerability

Please report security issues through GitHub's private vulnerability reporting
("Security" tab → "Report a vulnerability") rather than a public issue.

Expect an initial response within 7 days. There is no bug bounty.

## Threat model — read this before running sextant on code you do not trust

sextant is a local developer tool. It has no network surface, no server component reachable
from outside the machine, and no authentication of its own. The security-relevant surface is
what it *executes* and what it *writes*.

### `sextant index` executes the target project's build

This is the single most important thing to know. Building a Swift index store requires
running the project's build system:

- `swift build --enable-index-store` **executes the target project's `Package.swift`**, which
  is arbitrary Swift code, plus any SwiftPM plugins and build tool plugins it declares.
- `sextant index --app` invokes `xcodebuild`, which **executes the project's build phases**,
  including "Run Script" phases.

This is inherent to the platform, not a defect in sextant: there is no way to produce a
semantic index without compiling the code. The consequence is concrete:

> **Running `sextant index` on an untrusted repository is equivalent to running that
> repository's build. Do not do it outside a sandbox.**

Mitigations in place:

- `index` prints a warning that it will execute the project manifest.
- The MCP server **refuses to trigger builds**. `--reindex` over MCP or the daemon is
  rejected, so an agent cannot cause a build as a side effect of a query. Index builds are an
  explicit CLI action by a human.
- Every other command (`map`, `api`, `search`, `lint`, `changed`, and all semantic queries)
  only *reads* — sources, the git index, and an existing index store. None of them compile.

Not yet implemented: running the build under a restricted environment (`sandbox-exec` or a
scrubbed env). Tracked as operational maturity work; until then the warning above stands.

### Local daemon (`sextant serve`)

`serve` listens on a unix domain socket under the user's cache directory, scoped per project.
Unix socket permissions mean any process running as the same user can send it requests — the
same trust boundary as that user's shell. It is not reachable over the network. The daemon
verifies that the project root sent by the client matches its own, so a client cannot make it
answer for a different project.

### What sextant writes

- Index store and IndexStoreDB database: `~/Library/Caches/sextant/`
- Parse and declaration caches, keyed by content hash: same cache directory
- Project config: `.sextant.json` in the project root, written only by `sextant init`
- MCP registration: `.mcp.json` in the project root, written only by `sextant init`,
  preserving any servers already registered there

sextant never writes to your source files.

### Telemetry

Opt-in only, local-only. Nothing is transmitted anywhere; there is no endpoint. It records
command names, durations, and exit status to a local file so that roadmap decisions are based
on measurements rather than guesses. It is off unless you turn it on.

### Untrusted input handling

`sextant` parses source files with SwiftSyntax and reads index stores produced by the Swift
toolchain. Malformed input is expected to produce an error or a degraded result, never a
silent wrong answer — the "loud degradation" property the tool is built around. If you find
input that makes sextant report a confident but incorrect result, that is a bug worth
reporting even if it is not memory-unsafe.
