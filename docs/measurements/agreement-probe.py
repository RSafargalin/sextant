"""Do the two tools return the same references — not for one symbol, but for a sample of them.

    python3 agreement.py <project> <sextant> <index store> [sample size]

sextant is asked by name; sourcekit-lsp is asked at the definition sextant reports, which hands it
the position for free — the bias is deliberate and runs against us, because an agent has to find
that position by itself.

Compared as sets of (file, line). Columns are left out: the two number them differently and a
disagreement about a column is not a disagreement about an answer.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader

_client = SourceFileLoader(
    "lsp_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lsp-client.py")).load_module()
LSP, position_of = _client.LSP, _client.position_of

PROJECT = os.path.abspath(sys.argv[1])
SEXTANT = sys.argv[2]
STORE = sys.argv[3]
SAMPLE = int(sys.argv[4]) if len(sys.argv) > 4 else 50
sourcekit = subprocess.run(["xcrun", "--find", "sourcekit-lsp"], capture_output=True,
                           text=True).stdout.strip()


SEMANTIC = {"refs", "defs", "callers", "callees", "context", "blast", "impls", "hierarchy"}


def sextant(*arguments):
    # `--index-store` belongs to the semantic commands; the structural ones reject it as a usage
    # error, and a usage error reads here as "the project has no symbols".
    store = ["--index-store", STORE] if arguments and arguments[0] in SEMANTIC else []
    result = subprocess.run([SEXTANT] + list(arguments) + ["--project", PROJECT] + store + ["--json"],
                            capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def sampled_names():
    """A reproducible sample: every declared type and function in the repository map, sorted and
    thinned. The map is the tool's own view of the project, so the sample is not hand-picked."""
    import re
    pattern = re.compile(r"\b(?:class|struct|enum|protocol|actor)\s+([A-Za-z_]\w*)|\bfunc\s+([A-Za-z_]\w*)")
    names = set()

    def walk(node):
        if isinstance(node, dict):
            header = node.get("header")
            if isinstance(header, str):
                match = pattern.search(header)
                if match:
                    names.add(match.group(1) or match.group(2))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(sextant("map"))
    unique = sorted(names)
    if not unique:
        return []
    step = max(1, len(unique) // SAMPLE)
    return unique[::step][:SAMPLE]


def sextant_answer(name):
    """(definition, references) as sextant sees them, or None when the name is not one symbol."""
    payload = sextant("refs", name)
    hits = payload.get("hits") if isinstance(payload, dict) else payload
    if not isinstance(hits, list) or len(hits) != 1:
        return None
    hit = hits[0]
    definition = hit.get("definition") or {}
    if not definition.get("path"):
        return None
    references = {(r["path"], r["line"]) for r in hit.get("references", []) if r.get("path")}
    return definition, references


lsp = LSP([sourcekit], PROJECT)
lsp.initialize()
opened = set()


def lsp_references(definition):
    relative = os.path.relpath(definition["path"], PROJECT)
    if relative.startswith(".."):
        return None
    if relative not in opened:
        try:
            lsp.open(relative, "swift")
        except OSError:
            return None
        opened.add(relative)
        time.sleep(0.3)
    at = {"line": definition["line"] - 1, "character": max(0, definition["column"] - 1)}
    reply, _ = lsp.request("textDocument/references",
                           {"textDocument": {"uri": lsp.uri(relative)}, "position": at,
                            "context": {"includeDeclaration": False}}, timeout=60)
    if reply is None or reply.get("result") is None:
        return None
    found = set()
    for item in reply["result"]:
        path = item["uri"].replace("file://", "")
        found.add((os.path.realpath(path), item["range"]["start"]["line"] + 1))
    return found


names = sampled_names()
print("sample: %d name(s) from the repository map" % len(names))

same, differ, skipped = 0, 0, 0
differences = []
started = time.time()
for name in names:
    answer = sextant_answer(name)
    if answer is None:
        skipped += 1
        continue
    definition, ours = answer
    theirs = lsp_references(definition)
    if theirs is None:
        skipped += 1
        continue
    ours = {(os.path.realpath(p), line) for p, line in ours}
    if ours == theirs:
        same += 1
    else:
        differ += 1
        differences.append((name, len(ours), len(theirs), sorted(ours - theirs)[:2], sorted(theirs - ours)[:2]))

print("compared: %d  ·  identical: %d  ·  different: %d  ·  skipped: %d  (%.0fs)"
      % (same + differ, same, differ, skipped, time.time() - started))
if same + differ:
    print("agreement: %.0f%%" % (100.0 * same / (same + differ)))
for name, ours_count, theirs_count, only_ours, only_theirs in differences[:12]:
    print("\n  %s: sextant %d, lsp %d" % (name, ours_count, theirs_count))
    if only_ours:
        print("     only sextant: %s" % ", ".join("%s:%d" % (os.path.basename(p), l) for p, l in only_ours))
    if only_theirs:
        print("     only lsp:     %s" % ", ".join("%s:%d" % (os.path.basename(p), l) for p, l in only_theirs))
lsp.close()
