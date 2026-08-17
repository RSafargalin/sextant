"""Ask sourcekit-lsp the questions an agent asks, and record what it answers and how long it took.

    python3 sourcekit-lsp-probe.py <project> <file> <needle> [occurrence] [language]

The three outcomes are kept apart on purpose: no reply within the timeout, an empty answer, and
an answer. An LSP server that is still indexing returns an empty list, which reads exactly like
"there are none" — the distinction is the point of the measurement, not a detail of it.

Prints the index directories under `.build` before and after, because whether the server reads
the store your build already wrote or builds its own is the question underneath the timings.
"""
import json
import os
import subprocess
import sys
import time
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader

_client = SourceFileLoader(
    "lsp_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lsp-client.py")).load_module()
LSP, position_of = _client.LSP, _client.position_of

project = os.path.abspath(sys.argv[1])
relative = sys.argv[2]
needle = sys.argv[3]
occurrence = int(sys.argv[4]) if len(sys.argv) > 4 else 0
language = sys.argv[5] if len(sys.argv) > 5 else "swift"
wait = float(os.environ.get("INDEX_WAIT", "1800"))
sourcekit = subprocess.run(["xcrun", "--find", "sourcekit-lsp"], capture_output=True,
                           text=True).stdout.strip()


def index_dirs():
    build = os.path.join(project, ".build")
    return sorted(e for e in os.listdir(build) if "index" in e) if os.path.isdir(build) else []


def progress(lsp, limit=8):
    seen = []
    for note in lsp.notes:
        if note.get("method") == "$/progress":
            value = note.get("params", {}).get("value", {})
            text = value.get("title") or value.get("message") or value.get("kind")
            if text and (not seen or seen[-1] != text):
                seen.append(text)
    return seen[-limit:]


def ask(lsp, label, method, params, timeout=45):
    reply, seconds = lsp.request(method, params, timeout=timeout)
    if reply is None:
        outcome = "NO REPLY within %ds" % timeout
    elif "error" in reply:
        outcome = "error " + json.dumps(reply["error"])[:160]
    elif not reply.get("result"):
        outcome = "empty"
    else:
        result = reply["result"]
        items = result if isinstance(result, list) else [result]
        outcome = "%d item(s)" % len(items)
    print("  %-52s %6.2fs  %s" % (label, seconds, outcome))
    return reply


print("project: %s" % project)
print("probe:   %s @ %s (occurrence %d)" % (needle, relative, occurrence))
print("index dirs before: %s" % index_dirs())

started = time.time()
lsp = LSP([sourcekit], project)
_, seconds = lsp.initialize()
print("initialize: %.2fs" % seconds)
text = lsp.open(relative, language)
at = position_of(text, needle, occurrence)
print("position: line %d, character %d" % (at["line"], at["character"]))

first = None
while time.time() - started < wait:
    reply, _ = lsp.request("textDocument/references",
                           {"textDocument": {"uri": lsp.uri(relative)}, "position": at,
                            "context": {"includeDeclaration": False}}, timeout=30)
    if reply and reply.get("result"):
        first = reply["result"]
        break
    print("  … %5.0fs waiting; server progress: %s" % (time.time() - started, progress(lsp)))
    time.sleep(5)

print("\nfirst non-empty references after %.1fs (from process start)" % (time.time() - started))
print("index dirs now: %s" % index_dirs())

if first is None:
    print("NO ANSWER within %.0fs" % wait)
else:
    files = Counter()
    for item in first:
        uri = item.get("uri") or item.get("targetUri") or ""
        files[uri.replace("file://" + project + "/", "")] += 1
    print("references: %d in %d file(s)" % (sum(files.values()), len(files)))
    for name, count in files.most_common(10):
        print("   %4d  %s" % (count, name))

print("\nwith the index warm:")
ask(lsp, "references (again)", "textDocument/references",
    {"textDocument": {"uri": lsp.uri(relative)}, "position": at,
     "context": {"includeDeclaration": False}})
ask(lsp, "definition", "textDocument/definition",
    {"textDocument": {"uri": lsp.uri(relative)}, "position": at})
ask(lsp, "implementation", "textDocument/implementation",
    {"textDocument": {"uri": lsp.uri(relative)}, "position": at})
prepared = ask(lsp, "prepareCallHierarchy", "textDocument/prepareCallHierarchy",
               {"textDocument": {"uri": lsp.uri(relative)}, "position": at})
if prepared and prepared.get("result"):
    incoming = ask(lsp, "incomingCalls", "callHierarchy/incomingCalls",
                   {"item": prepared["result"][0]})
    for call in (incoming.get("result") or [])[:8]:
        item = call.get("from", {})
        print("       %-40s %s" % (item.get("name"),
                                   item.get("uri", "").replace("file://" + project + "/", "")))
ask(lsp, "workspace/symbol '%s'" % needle.split("(")[0].split(":")[0],
    "workspace/symbol", {"query": needle.split("(")[0].split(":")[0]})

print("\nserver progress seen: %s" % progress(lsp, limit=12))
lsp.close()
print("index dirs after: %s" % index_dirs())
