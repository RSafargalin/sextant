# Measurements

Scripts that produced a number recorded elsewhere in the documentation. They live here so a claim
can be re-checked rather than believed, and so a reopened question starts from the previous stand
instead of from scratch.

| Script | Question it answers | Where the numbers are |
|---|---|---|
| `shared-index-database.py` | Does sharing one IndexStoreDB directory between processes cost anything? | [roadmap](../roadmap.md#a-shared-indexstoredb-directory-across-processes--harm-not-confirmed-2026-08-17) |
| `shared-index-database-control.py` | The control for it: the same concurrency with one database per process | same |
| `sourcekit-lsp-probe.py` | What sourcekit-lsp answers about a symbol, how long it waits for its own index, and whether it reads the store the build already wrote | [roadmap](../roadmap.md#sourcekit-lsp-and-serena-on-the-same-questions--spike-2026-08-17) |
| `serena-probe.py` | The same questions through Serena's MCP tools | same |
| `lsp-client.py` | Shared: a minimal LSP client over stdio, imported by the probe | — |

The two probes take a project and, for the LSP one, a file, a symbol spelling and which occurrence
of it to stand on:

```bash
python3 docs/measurements/sourcekit-lsp-probe.py /path/to/package Source/Core/Session.swift "Session: @unchecked"
python3 docs/measurements/serena-probe.py /path/to/serena /path/to/package "Session[0]"
```

`INDEX_WAIT` caps how long the LSP probe waits for a first non-empty answer (default 1800 s). The
first run against a project builds sourcekit-lsp's own index under `.build/index-build` and is slow
by that much; a second run is warm. Serena is not vendored — install it separately; its Swift
backend is sourcekit-lsp, so the two probes ask the same server two different ways.

The database scripts take the binary, the project, a symbol and a store:

```bash
python3 docs/measurements/shared-index-database.py \
    "$(swift build --show-bin-path)/sextant" /path/to/project SomeSymbol /path/to/index/store
python3 docs/measurements/shared-index-database-control.py \
    "$(swift build --show-bin-path)/sextant" /path/to/project SomeSymbol /path/to/index/store 4
```

The control copies the store once per process (528 MB per copy on the reference project) and removes
the copies and their databases afterwards. Both scripts delete `~/Library/Caches/sextant/index-db`
entries for the stores they measure — that is a cache, and a cold start is one of the cases measured.
