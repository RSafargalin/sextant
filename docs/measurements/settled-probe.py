"""What the answer becomes once the editor's index has stopped growing.

    python3 settled.py <project> <file> <needle> [occurrence]

The first non-empty answer is not the answer: sourcekit-lsp indexes in the background and replies
from whatever it has prepared, so an early reading is a partial one — the trap that once made two
tools look like they agreed. This polls until the count stops changing, and prints the whole
sequence so the settling is visible rather than asserted.
"""
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
RELATIVE = sys.argv[2]
NEEDLE = sys.argv[3]
OCCURRENCE = int(sys.argv[4]) if len(sys.argv) > 4 else 0
DEADLINE = float(os.environ.get("SETTLE_DEADLINE", "3600"))
STABLE_FOR = float(os.environ.get("STABLE_FOR", "180"))
sourcekit = subprocess.run(["xcrun", "--find", "sourcekit-lsp"], capture_output=True,
                           text=True).stdout.strip()

lsp = LSP([sourcekit], PROJECT)
lsp.initialize()
text = lsp.open(RELATIVE, "swift")
at = position_of(text, NEEDLE, OCCURRENCE)

started = time.time()
last, unchanged_since, history = None, None, []
while time.time() - started < DEADLINE:
    reply, _ = lsp.request("textDocument/references",
                           {"textDocument": {"uri": lsp.uri(RELATIVE)}, "position": at,
                            "context": {"includeDeclaration": False}}, timeout=60)
    count = len(reply.get("result") or []) if reply else 0
    now = time.time() - started
    if count != last:
        history.append((now, count))
        print("  %6.0fs  %d reference(s)" % (now, count))
        last, unchanged_since = count, time.time()
    elif time.time() - unchanged_since >= STABLE_FOR:
        break
    time.sleep(15)

print("\nsettled at %d reference(s) after %.0fs; %d change(s) on the way"
      % (last or 0, time.time() - started, len(history)))
files = {}
reply, _ = lsp.request("textDocument/references",
                       {"textDocument": {"uri": lsp.uri(RELATIVE)}, "position": at,
                        "context": {"includeDeclaration": False}}, timeout=60)
for item in (reply.get("result") or []) if reply else []:
    name = item["uri"].replace("file://" + PROJECT + "/", "")
    files[name] = files.get(name, 0) + 1
print("in %d file(s); top:" % len(files))
for name, count in sorted(files.items(), key=lambda pair: -pair[1])[:6]:
    print("   %5d  %s" % (count, name))
lsp.close()
