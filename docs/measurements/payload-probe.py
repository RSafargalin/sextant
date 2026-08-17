"""How many bytes the same answer costs, in the shape each tool actually returns it.

    python3 payload.py <project> <file> <needle> <sextant> <symbol> [index store]

No modelling of an agent's path: this compares the payloads themselves — the LSP `references`
result as JSON, and sextant's answer in the two shapes it offers. What LSP needs before it can be
asked at all (a file and a position) is not counted here; that is stated in prose, not smuggled
into a number.
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
RELATIVE, NEEDLE, SEXTANT, SYMBOL = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
STORE = sys.argv[6] if len(sys.argv) > 6 else None
sourcekit = subprocess.run(["xcrun", "--find", "sourcekit-lsp"], capture_output=True,
                           text=True).stdout.strip()

lsp = LSP([sourcekit], PROJECT)
lsp.initialize()
text = lsp.open(RELATIVE, "swift")
at = position_of(text, NEEDLE, 0)

# Let the background index settle: an early answer is smaller because it is partial, and a byte
# count taken then would flatter the wrong side.
last, stable_since = None, time.time()
while time.time() - stable_since < 90:
    reply, _ = lsp.request("textDocument/references",
                           {"textDocument": {"uri": lsp.uri(RELATIVE)}, "position": at,
                            "context": {"includeDeclaration": False}}, timeout=60)
    count = len(reply.get("result") or []) if reply else 0
    if count != last:
        last, stable_since = count, time.time()
    time.sleep(10)

lsp_payload = json.dumps(reply["result"], separators=(",", ":"))
print("sourcekit-lsp: %d reference(s), %d bytes of JSON" % (last, len(lsp_payload)))
lsp.close()


def sextant(*arguments):
    store = ["--index-store", STORE] if STORE else []
    result = subprocess.run([SEXTANT, *arguments, SYMBOL, "--project", PROJECT] + store,
                            capture_output=True, text=True)
    return result.stdout


for label, arguments in (("grouped (default when piped)", ("refs",)),
                         ("line by line (--full)", ("refs", "--full")),
                         ("machine contract (--json)", ("refs", "--json"))):
    output = sextant(*arguments)
    print("sextant %-28s %6d bytes" % (label + ":", len(output)))
