#!/bin/sh
# Feeds one tool-use event to `sextant hook`, which records the kind of act and the shape of the
# query — never the query, the command, the path or the project — under ~/Library/Caches/sextant.
#
# Silent and exit 0 whatever happens, including a missing binary: this runs before every tool
# call, and a metric that can fail a tool call is worse than no metric.
. "$(dirname "$0")/resolve-sextant.sh"

binary=$(resolve_sextant) || exit 0
"$binary" hook >/dev/null 2>&1 || true
exit 0
