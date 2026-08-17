#!/bin/sh
# Prints the path of the sextant binary, or nothing and a non-zero status when there is none.
#
# PATH comes first, so a copy the user chose to put in front keeps winning. The rest are the
# three directories the documented installation routes write to: `make install`, Homebrew on
# Apple Silicon, Homebrew on Intel. They are searched because a client started from the Finder
# does not inherit a login shell's PATH, and a server that fails there fails invisibly.
resolve_sextant() {
    if command -v sextant >/dev/null 2>&1; then
        command -v sextant
        return 0
    fi
    for candidate in "$HOME/.local/bin/sextant" /opt/homebrew/bin/sextant /usr/local/bin/sextant; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
