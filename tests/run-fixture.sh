#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT_DIR/scripts/resolve-stacks.sh"
FIXTURE_DIR="$ROOT_DIR/tests/fixtures"
OUTPUT_FILE="$FIXTURE_DIR/sample.out"

chmod +x "$SCRIPT" >/dev/null 2>&1 || true
chmod +x "$FIXTURE_DIR/mock-addr2line.sh" >/dev/null 2>&1 || true

rm -f "$OUTPUT_FILE"

"$SCRIPT" \
  --maps "$FIXTURE_DIR/sample.maps" \
  --symbol-dir "$FIXTURE_DIR/symbols" \
  --addr2line "$FIXTURE_DIR/mock-addr2line.sh" \
  --input "$FIXTURE_DIR/sample.stacks" \
  --output "$OUTPUT_FILE"

if ! diff -u "$FIXTURE_DIR/sample.expected" "$OUTPUT_FILE"; then
  echo "Fixture test failed" >&2
  exit 1
fi

echo "Fixture test passed"
