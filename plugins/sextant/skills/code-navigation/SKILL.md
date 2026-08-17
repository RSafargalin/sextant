---
name: code-navigation
description: Use when navigating or changing Swift, Objective-C, C or C++ code — finding where a symbol is defined, who calls it, what implements a protocol, what a change would break, what a package or type exposes, or what changed between revisions. Says when to ask the sextant MCP server instead of running Grep, Glob or reading files.
---

# Navigating a compiled codebase

The project's build already wrote an index store — the data behind "jump to definition" in an
editor. The `sextant` MCP tools read it. An exact answer is one call away, so a grep-and-read
loop over the same question is both slower and wrong more often: a text search finds a name in a
comment, misses a call spelled through a protocol, and cannot see across the Swift ↔ Objective-C
boundary.

## Ask the index, not the filesystem

| The question | What to do |
|---|---|
| Where is `X` defined? Who uses it? What does it call? | One `context` call — not a Grep followed by three Reads |
| What breaks if I change `X`? | `blast_radius` |
| Who calls this function? | `find_callers` — it accounts for protocol dispatch, which grep cannot |
| What implements this protocol / subclasses this type? | `list_implementations` |
| What does this package or type expose? | `api` — an order of magnitude cheaper than reading the sources |
| Where is this code shape used (`try? $X.save()`, `[$X reloadData]`)? | `structural_search` — an AST pattern, not a regex |
| What changed between two revisions? | `changed` — declaration-level, not a line diff |
| I need the implementation, not the signature | `body` |

Reach for Grep or a file read when the target is not a symbol: a string literal, a comment, a
build setting, a resource, a file whose name you already know.

## Read the index line of every answer

Every answer carries a line naming the store it was read from and whether it is fresh — the last
line of the result, in brackets. Treat it as part of the answer:

- **stale** — the store predates the current sources; a symbol added since the last build is
  absent from it. Say so rather than reporting "no references".
- **no index** — the semantic tools return a hint instead of an empty result. Building one runs
  the project's own build (`sextant index`), and that is the user's decision to make, not a step
  to take on their behalf. Ask.
- `repo_map`, `structural_search` and `lint` need no index for Swift; for Objective-C, C and C++
  they need the compile flags that `sextant index` records.

## What it does not see

Interface Builder. A class, an outlet or an action bound only from a `.storyboard` or `.xib` is
invisible to every count, so "no references" for a view-controller class is a claim to hedge.
