#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: heaptrack-to-raw-stack.sh <heaptrack.raw.gz> [output_stack_file]

Converts a heaptrack raw capture into a flamegraph-compatible stack file
(using leaked bytes as cost) and writes it to the target path.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

input_gz=$1
output_stack=${2:-stack.txt}

temp_interpreted=$(mktemp)
cleanup() {
  rm -f "$temp_interpreted"
}
trap cleanup EXIT

if [[ ! -f "$input_gz" ]]; then
  echo "Error: input file not found: $input_gz" >&2
  exit 1
fi

zcat "$input_gz" | heaptrack_interpret > "$temp_interpreted"
heaptrack_print "$temp_interpreted" --flamegraph-cost-type leaked -F "$output_stack"

echo "Success: $output_stack generated"
