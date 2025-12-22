#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: heaptrack-to-raw-stack.sh <heaptrack.raw.gz> [output_stack_file]

Converts a heaptrack raw capture into a flamegraph-compatible stack file
(using leaked bytes as cost) and writes it to the target path.
Options:
  --cost-type TYPE   leaked|allocations|temporary|peak (default: leaked)
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

if [[ ${#args[@]} -lt 1 || ${#args[@]} -gt 2 ]]; then
  usage
  exit 1
fi

case "$cost_type" in
  leaked|allocations|temporary|peak) ;;
  *)
    echo "Error: invalid --cost-type: $cost_type (expected leaked|allocations|temporary|peak)" >&2
    exit 1
    ;;
esac

input_gz=${args[0]}
output_stack=${args[1]:-stack.txt}

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
heaptrack_print "$temp_interpreted" --flamegraph-cost-type "$cost_type" -F "$output_stack"

echo "Success: $output_stack generated (cost-type=$cost_type)"
