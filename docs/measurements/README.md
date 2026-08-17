# Measurements

Scripts that produced a number recorded elsewhere in the documentation. They live here so a claim
can be re-checked rather than believed, and so a reopened question starts from the previous stand
instead of from scratch.

| Script | Question it answers | Where the numbers are |
|---|---|---|
| `shared-index-database.py` | Does sharing one IndexStoreDB directory between processes cost anything? | [roadmap](../roadmap.md#a-shared-indexstoredb-directory-across-processes--harm-not-confirmed-2026-08-17) |
| `shared-index-database-control.py` | The control for it: the same concurrency with one database per process | same |

Both take the binary, the project, a symbol and a store:

```bash
python3 docs/measurements/shared-index-database.py \
    "$(swift build --show-bin-path)/sextant" /path/to/project SomeSymbol /path/to/index/store
python3 docs/measurements/shared-index-database-control.py \
    "$(swift build --show-bin-path)/sextant" /path/to/project SomeSymbol /path/to/index/store 4
```

The control copies the store once per process (528 MB per copy on the reference project) and removes
the copies and their databases afterwards. Both scripts delete `~/Library/Caches/sextant/index-db`
entries for the stores they measure — that is a cache, and a cold start is one of the cases measured.
