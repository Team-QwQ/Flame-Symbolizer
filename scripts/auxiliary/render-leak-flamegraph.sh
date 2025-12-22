#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: render-leak-flamegraph.sh [--cost-type TYPE] [stack_file] [output_svg]

Generate a leak-focused flamegraph from a stackcollapse-style file.
Defaults: cost-type=leaked, stack_file=./stack.txt, output_svg=raw-leak.svg
Options:
    --cost-type TYPE   leaked|allocations|temporary|peak (affects title/countname)
Env: FLAMEGRAPH_BIN to override flamegraph.pl path.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi

cost_type="leaked"
args=()
while (($#)); do
    case "$1" in
        --cost-type)
            shift || true
            cost_type=${1:-}
            ;;
        *)
            args+=("$1")
            ;;
    esac
    shift || true
done

case "$cost_type" in
    leaked|allocations|temporary|peak) ;;
    *)
        echo "Error: invalid --cost-type: $cost_type (expected leaked|allocations|temporary|peak)" >&2
        exit 1
        ;;
esac

STACK_FILE=${args[0]:-./stack.txt}
OUTPUT_SVG=${args[1]:-raw-leak.svg}
FLAMEGRAPH_BIN=${FLAMEGRAPH_BIN:-flamegraph.pl}

title="Heaptrack $cost_type"
countname="bytes"
case "$cost_type" in
    leaked)
        title="Raw Leak Memory Graph"
        countname="bytes"
        ;;
    allocations)
        title="Allocations Flamegraph"
        countname="allocs"
        ;;
    temporary)
        title="Temporary Memory Flamegraph"
        countname="bytes"
        ;;
    peak)
        title="Peak Memory Flamegraph"
        countname="bytes"
        ;;
esac

if [[ ! -f "$STACK_FILE" ]]; then
    echo "Error: stack file not found: $STACK_FILE" >&2
    exit 1
fi

if ! command -v "$FLAMEGRAPH_BIN" >/dev/null 2>&1; then
    echo "Error: flamegraph binary not found: $FLAMEGRAPH_BIN" >&2
    echo "Hint: set FLAMEGRAPH_BIN or add flamegraph.pl to PATH" >&2
    exit 1
fi

< "$STACK_FILE" "$FLAMEGRAPH_BIN" --colors=mem --title "$title" --countname="$countname" > "$OUTPUT_SVG"

echo "Success: $OUTPUT_SVG generated (cost-type=$cost_type)"