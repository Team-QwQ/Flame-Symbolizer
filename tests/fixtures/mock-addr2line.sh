#!/usr/bin/env bash
set -euo pipefail

binary=""
declare -a addresses=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      shift
      binary="${1:-}"
      [[ -n "$binary" ]] || { echo "missing binary path" >&2; exit 1; }
      ;;
    -*)
      # ignore other flags like -f, -C
      ;;
    *)
      addresses+=("$1")
      ;;
  esac
  shift || true
done

addr="${addresses[-1]:-}"
[[ -n "$binary" && -n "$addr" ]] || {
  echo "??"
  echo "??:0"
  exit 0
}

basename="${binary##*/}"
case "$basename:$addr" in
  sampleapp:0x100)
    echo "main"
    echo "src/main.c:42"
    ;;
  sampleapp:0x200)
    echo "worker"
    echo "src/main.c:87"
    ;;
  libsample.so:0x100)
    echo "helper_one"
    echo "lib/helper.c:10"
    ;;
  libsample.so:0x200)
    echo "helper_two"
    echo "lib/helper.c:25"
    ;;
  *)
    echo "??"
    echo "??:0"
    ;;
esac
