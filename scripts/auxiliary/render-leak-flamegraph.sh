#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: render-leak-flamegraph.sh [stack_file] [output_svg]

Generate a leak-focused flamegraph from a stackcollapse-style file.
Defaults: stack_file=./stack.txt, output_svg=raw-leak.svg
Env: FLAMEGRAPH_BIN to override flamegraph.pl path.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

STACK_FILE=${1:-./stack.txt}
OUTPUT_SVG=${2:-raw-leak.svg}
FLAMEGRAPH_BIN=${FLAMEGRAPH_BIN:-flamegraph.pl}

if [[ ! -f "$STACK_FILE" ]]; then
    echo "Error: stack file not found: $STACK_FILE" >&2
    exit 1
fi

if ! command -v "$FLAMEGRAPH_BIN" >/dev/null 2>&1; then
    echo "Error: flamegraph binary not found: $FLAMEGRAPH_BIN" >&2
    echo "Hint: set FLAMEGRAPH_BIN or add flamegraph.pl to PATH" >&2
    exit 1
fi

< "$STACK_FILE" "$FLAMEGRAPH_BIN" --colors=mem --title "Raw Leak Memory Graph" --countname=bytes > "$OUTPUT_SVG"

echo "Success: $OUTPUT_SVG generated"