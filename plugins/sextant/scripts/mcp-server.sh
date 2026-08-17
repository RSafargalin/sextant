#!/bin/sh
# Starts `sextant mcp` for the project Claude Code passes as the first argument.
#
# A missing binary is reported on stderr and exits non-zero: the client shows the server as
# failed, which is the only signal a user gets from a stdio server that never speaks.
set -eu

. "$(dirname "$0")/resolve-sextant.sh"

if ! binary=$(resolve_sextant); then
    echo "sextant: binary not found in PATH, ~/.local/bin or Homebrew." >&2
    echo "  install it:  brew tap RSafargalin/tap && brew trust RSafargalin/tap && brew install sextant" >&2
    echo "  other routes: https://github.com/RSafargalin/sextant#installation" >&2
    exit 1
fi

# An empty or unresolved project directory is dropped rather than passed on: sextant then falls
# back to CLAUDE_PROJECT_DIR and to the working directory, and `--project ''` would be an error.
project="${1-}"
if [ -n "$project" ] && [ -d "$project" ]; then
    exec "$binary" mcp --project "$project"
fi
exec "$binary" mcp
