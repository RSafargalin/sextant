---
description: Check that sextant is installed and usable in this project, and fix what is missing.
---

Get sextant working in the current project. Report what you find at each step; do not run a
build without asking.

1. **Is the binary there?** Run `sextant --version`.

   If the command is not found, the plugin's tools cannot work — the plugin registers the
   server, Homebrew installs the binary. Offer to run:

   ```
   brew tap RSafargalin/tap && brew trust RSafargalin/tap && brew install sextant
   ```

   `brew trust` is required for a third-party tap. Other routes, including a prebuilt binary
   without Homebrew, are in https://github.com/RSafargalin/sextant#installation. Wait for the
   user to agree before installing anything.

2. **Does the setup hold together?** Run `sextant doctor --project "$CLAUDE_PROJECT_DIR"` and
   relay its output as it stands — it is a checklist of sources, `libIndexStore`, the index
   store and its freshness, and it names what is missing.

3. **Is there an index?** The semantic tools need one; without it they return a hint rather than
   a wrong answer, and the structural tools still work for Swift.

   Building one **runs the project's own build** — `Package.swift`, SwiftPM plugins and macros
   are code, and with `--app` an Xcode `Run Script` phase is a shell script. So it is the user's
   call. Tell them what it runs, then offer, whichever fits:

   - `sextant index` — SwiftPM projects
   - `sextant index --app` — an Xcode app target (add `--scheme <name>` when there are several)
   - `sextant index --no-build` — the project is already built; this finds the existing store
     and runs nothing

4. **Confirm it answers.** Ask the sextant MCP server about one symbol you have seen in this
   project and show the result. If the server is not connected, say so — the plugin registers it
   at startup, so a client started before the install needs a restart.

Close with one line: what works now, and what is left for the user to decide.
