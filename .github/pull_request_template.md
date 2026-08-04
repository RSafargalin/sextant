## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- What was wrong or missing. If this is a bug fix, describe the failure, not just the fix. -->

## How it was verified

<!--
Be specific about the level of evidence — this project distinguishes them (see AGENTS.md):
  - verified in code (file:line)
  - verified by running it (paste the output)
  - verified by a test (name it)
"Should work" is not verification.
-->

## Checklist

- [ ] `make ci` passes locally
- [ ] A test covers the changed behaviour — including the awkward case, not only the happy path
- [ ] `CHANGELOG.md` updated under `Unreleased` if this is user-visible
- [ ] No new source of truth introduced (help text, MCP tool list and index freshness each have exactly one — see AGENTS.md)
- [ ] If a result can be heuristic or a textual fallback, the output says so

## Compatibility

- [ ] This changes a CLI flag, JSON schema, MCP tool name, or exit code

<!-- If checked: describe the break. These are covered by semver. -->
