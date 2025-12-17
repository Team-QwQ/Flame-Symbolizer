#!/usr/bin/env bash
set -euo pipefail

print_help() {
  cat <<'EOF'
Usage: resolve-stacks.sh [options]

Required:
  --maps PATH                 Path to /proc/<pid>/maps style file used to recover load addresses.

Optional:
  --symbol-dir DIR            Directory containing symbolized binaries; may be repeated, supports glob/relative paths.
  --input FILE                Input file (stackcollapse format). Defaults to stdin when omitted or set to '-'.
  --output FILE               Output file. Defaults to stdout when omitted or set to '-'.
  --addr2line PATH            addr2line binary to invoke (default: value of $ADDR2LINE or 'addr2line').
  --addr2line-flags STRING    Extra flags passed verbatim to addr2line (e.g. "-f -C").
  -h, --help                  Show this message and exit.
EOF
}

abort() {
  echo "[ERROR] $1" >&2
  exit 1
}

warn() {
  echo "[WARN] $1" >&2
}

MAPS_FILE=""
SYMBOL_DIRS=()
INPUT_PATH="-"
OUTPUT_PATH="-"
ADDR2LINE_BIN="${ADDR2LINE:-addr2line}"
ADDR2LINE_FLAGS=""

declare -A ADDRESS_CACHE=()
declare -a MAP_STARTS=()
declare -a MAP_ENDS=()
declare -a MAP_OFFSETS=()
declare -a MAP_PATHS=()
declare -a MAP_ADJUSTS=()
declare -a RESOLVED_SYMBOL_DIRS=()
declare -A BINARY_CACHE=()
declare -A ADDRESS_META=()
declare -A ADDRESS_SEGMENT=()
declare -A ADDRESS_BINARY=()
declare -A ADDRESS_MODULE=()

SYMBOL_SEARCH_AVAILABLE=0
readonly MISSING_BINARY_SENTINEL="__MISSING_BINARY__"
readonly UNRESOLVABLE_SENTINEL="__UNRESOLVABLE__"


trim_whitespace() {
  local str="$1"
  str="${str#${str%%[![:space:]]*}}"
  str="${str%${str##*[![:space:]]}}"
  printf '%s' "$str"
}

is_hex_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]+$ ]]
}

append_symbol_dir_if_missing() {
  local dir="$1"
  local existing
  for existing in "${RESOLVED_SYMBOL_DIRS[@]}"; do
    if [[ "$existing" == "$dir" ]]; then
      return
    fi
  done
  RESOLVED_SYMBOL_DIRS+=("$dir")
}

resolve_symbol_dirs() {
  RESOLVED_SYMBOL_DIRS=()
  SYMBOL_SEARCH_AVAILABLE=0

  if [[ ${#SYMBOL_DIRS[@]} -eq 0 ]]; then
    warn "No --symbol-dir supplied; symbol resolution will remain raw."
    return
  fi

  local pattern matches=() candidate matched abs oldIFS
  for pattern in "${SYMBOL_DIRS[@]}"; do
    matches=()
    oldIFS="$IFS"
    IFS=$'\n'
    shopt -s nullglob
    matches=( $pattern )
    shopt -u nullglob
    IFS="$oldIFS"
    if [[ ${#matches[@]} -eq 0 ]]; then
      matches=("$pattern")
    fi

    matched=0
    for candidate in "${matches[@]}"; do
      if [[ -d "$candidate" ]]; then
        abs=$(cd "$candidate" && pwd -P)
        append_symbol_dir_if_missing "$abs"
        matched=1
      fi
    done

    if [[ $matched -eq 0 ]]; then
      warn "Symbol directory pattern matched nothing usable: $pattern"
    fi
  done

  if [[ ${#RESOLVED_SYMBOL_DIRS[@]} -eq 0 ]]; then
    warn "Symbol directories resolved to empty set; addresses will remain as raw hex."
    SYMBOL_SEARCH_AVAILABLE=0
  else
    SYMBOL_SEARCH_AVAILABLE=1
  fi
}

load_maps() {
  MAP_STARTS=()
  MAP_ENDS=()
  MAP_OFFSETS=()
  MAP_PATHS=()
  MAP_ADJUSTS=()

  local line start_hex end_hex perms offset_hex dev inode path start_dec end_dec offset_dec adjust
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([0-9a-fA-F]+)-([0-9a-fA-F]+)[[:space:]]+([rwxps-]{4})[[:space:]]+([0-9a-fA-F]+)[[:space:]]+([0-9a-fA-F]{2}:[0-9a-fA-F]{2})[[:space:]]+([0-9]+)[[:space:]]*(.*)$ ]]; then
      start_hex="${BASH_REMATCH[1]}"
      end_hex="${BASH_REMATCH[2]}"
      perms="${BASH_REMATCH[3]}"
      offset_hex="${BASH_REMATCH[4]}"
      path="$(trim_whitespace "${BASH_REMATCH[7]}")"

      [[ -z "$path" ]] && continue

      start_dec=$((16#$start_hex))
      end_dec=$((16#$end_hex))
      offset_dec=$((16#$offset_hex))
      adjust=$((start_dec - offset_dec))

      MAP_STARTS+=("$start_dec")
      MAP_ENDS+=("$end_dec")
      MAP_OFFSETS+=("$offset_dec")
      MAP_PATHS+=("$path")
      MAP_ADJUSTS+=("$adjust")
    fi
  done <"$MAPS_FILE"

  if [[ ${#MAP_STARTS[@]} -eq 0 ]]; then
    abort "No usable mappings found in maps file: $MAPS_FILE"
  fi
}

find_map_segment() {
  local addr_dec="$1"
  local idx
  for idx in "${!MAP_STARTS[@]}"; do
    if (( addr_dec >= MAP_STARTS[idx] && addr_dec < MAP_ENDS[idx] )); then
      printf '%s' "$idx"
      return 0
    fi
  done
  return 1
}

locate_binary_for_module() {
  local module_path="$1"
  local cached="${BINARY_CACHE[$module_path]:-}"
  if [[ -n "$cached" ]]; then
    if [[ "$cached" == "$MISSING_BINARY_SENTINEL" ]]; then
      return 1
    fi
    printf '%s' "$cached"
    return 0
  fi

  if [[ $SYMBOL_SEARCH_AVAILABLE -eq 0 ]]; then
    BINARY_CACHE["$module_path"]="$MISSING_BINARY_SENTINEL"
    warn "No symbol directories available to resolve $module_path"
    return 1
  fi

  local sanitized="${module_path#/}"
  local dir candidate basename
  for dir in "${RESOLVED_SYMBOL_DIRS[@]}"; do
    candidate="${dir%/}/${sanitized}"
    if [[ -f "$candidate" ]]; then
      BINARY_CACHE["$module_path"]="$candidate"
      printf '%s' "$candidate"
      return 0
    fi
  done

  basename="${sanitized##*/}"
  if [[ -z "$basename" ]]; then
    basename="$sanitized"
  fi

  for dir in "${RESOLVED_SYMBOL_DIRS[@]}"; do
    candidate=$(find "$dir" -type f -name "$basename" -print -quit 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      BINARY_CACHE["$module_path"]="$candidate"
      printf '%s' "$candidate"
      return 0
    fi
  done

  BINARY_CACHE["$module_path"]="$MISSING_BINARY_SENTINEL"
  warn "missing binary for $module_path"
  return 1
}

prepare_address_metadata() {
  local token="$1"
  local status="${ADDRESS_META[$token]:-}"
  if [[ -n "$status" ]]; then
    [[ "$status" == "$UNRESOLVABLE_SENTINEL" ]] && return 1
    return 0
  fi

  local addr_dec=$((token))
  local segment_idx
  if ! segment_idx=$(find_map_segment "$addr_dec"); then
    warn "address $token not covered by maps; keeping raw address"
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  local module_path="${MAP_PATHS[$segment_idx]}"
  if [[ -z "$module_path" || "$module_path" == "["* ]]; then
    warn "address $token maps to non-file region '$module_path'; keeping raw address"
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  local binary_path
  if ! binary_path=$(locate_binary_for_module "$module_path"); then
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  ADDRESS_SEGMENT["$token"]="$segment_idx"
  ADDRESS_BINARY["$token"]="$binary_path"
  ADDRESS_MODULE["$token"]="$module_path"
  ADDRESS_META["$token"]="READY"
  return 0
}

symbolize_address() {
  local token="$1"
  local status="${ADDRESS_META[$token]:-}"
  if [[ "$status" != "READY" ]]; then
    return 1
  fi

  local segment_idx="${ADDRESS_SEGMENT[$token]:-}"
  local binary_path="${ADDRESS_BINARY[$token]:-}"
  local module_path="${ADDRESS_MODULE[$token]:-}"
  if [[ -z "$segment_idx" || -z "$binary_path" ]]; then
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  local adjust="${MAP_ADJUSTS[$segment_idx]}"
  local addr_dec=$((token))
  local rel_dec=$((addr_dec - adjust))
  if (( rel_dec < 0 )); then
    warn "address $token yielded negative relative offset for $module_path"
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  printf -v rel_hex "0x%x" "$rel_dec"

  local cmd=("$ADDR2LINE_BIN" "-f" "-C")
  if [[ -n "$ADDR2LINE_FLAGS" ]]; then
    local extra_flags=()
    read -r -a extra_flags <<< "$ADDR2LINE_FLAGS"
    if [[ ${#extra_flags[@]} -gt 0 ]]; then
      cmd+=("${extra_flags[@]}")
    fi
  fi
  cmd+=("-e" "$binary_path" "$rel_hex")

  local -a lines=()
  if ! mapfile -t lines < <("${cmd[@]}" 2>/dev/null); then
    warn "addr2line failed for $module_path@$rel_hex"
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  local func="${lines[0]:-??}"
  local src="${lines[1]:-??:0}"
  if [[ -z "$func" ]]; then func="??"; fi
  if [[ -z "$src" ]]; then src="??:0"; fi

  local pretty
  if [[ "$src" == "??:0" || "$src" == "??" ]]; then
    if [[ "$func" == "??" ]]; then
      ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
      return 1
    fi
    pretty="$func ($module_path)"
  else
    pretty="$func ($src)"
  fi

  printf '%s' "$pretty"
}

resolve_frame_token() {
  local token="$1"
  if [[ -n "${ADDRESS_CACHE[$token]:-}" ]]; then
    printf '%s' "${ADDRESS_CACHE[$token]}"
    return
  fi

  if ! is_hex_address "$token"; then
    ADDRESS_CACHE["$token"]="$token"
    printf '%s' "$token"
    return
  fi

  if prepare_address_metadata "$token"; then
    local symbol
    if symbol=$(symbolize_address "$token"); then
      ADDRESS_CACHE["$token"]="$symbol"
      printf '%s' "$symbol"
      return
    fi
  fi

  ADDRESS_CACHE["$token"]="$token"
  printf '%s' "$token"
}

process_stack_line() {
  local line="$1"

  if [[ -z "$line" ]]; then
    printf '\n'
    return
  fi

  local stack_part count
  if [[ "$line" =~ ^(.+[^[:space:]])[[:space:]]+([0-9]+)$ ]]; then
    stack_part="${BASH_REMATCH[1]}"
    count="${BASH_REMATCH[2]}"
  else
    warn "Malformed stack line (kept as-is): $line"
    printf '%s\n' "$line"
    return
  fi

  IFS=';' read -r -a frames <<< "$stack_part"
  local idx frame
  for idx in "${!frames[@]}"; do
    frame="$(trim_whitespace "${frames[$idx]}")"
    frames[$idx]="$(resolve_frame_token "$frame")"
  done

  local joined
  local IFS=';'
  joined="${frames[*]}"
  printf '%s %s\n' "$joined" "$count"
}

process_stream() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    process_stack_line "$line"
    line=""
  done
}

# argument parsing
while (($#)); do
  case "$1" in
    --maps)
      shift || abort "--maps requires a path"
      MAPS_FILE="$1"
      ;;
    --symbol-dir)
      shift || abort "--symbol-dir requires a directory"
      SYMBOL_DIRS+=("$1")
      ;;
    --input)
      shift || abort "--input requires a file path"
      INPUT_PATH="$1"
      ;;
    --output)
      shift || abort "--output requires a file path"
      OUTPUT_PATH="$1"
      ;;
    --addr2line)
      shift || abort "--addr2line requires a binary path"
      ADDR2LINE_BIN="$1"
      ;;
    --addr2line-flags)
      shift || abort "--addr2line-flags requires a string"
      ADDR2LINE_FLAGS="$1"
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -* )
      abort "Unknown option: $1"
      ;;
    *)
      abort "Unexpected positional argument: $1"
      ;;
  esac
  shift || true
done

[[ -n "$MAPS_FILE" ]] || abort "--maps is required"
[[ -r "$MAPS_FILE" ]] || abort "Cannot read maps file: $MAPS_FILE"

if [[ "$INPUT_PATH" != "-" && ! -r "$INPUT_PATH" ]]; then
  abort "Cannot read input file: $INPUT_PATH"
fi

if [[ "$OUTPUT_PATH" != "-" ]]; then
  OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
  if [[ ! -d "$OUTPUT_DIR" ]]; then
    abort "Output directory does not exist: $OUTPUT_DIR"
  fi
fi

if ! command -v "$ADDR2LINE_BIN" >/dev/null 2>&1; then
  abort "addr2line binary not found: $ADDR2LINE_BIN"
fi

# Placeholder for future stages
run_symbolization() {
  resolve_symbol_dirs
  load_maps

  local input_source
  if [[ "$INPUT_PATH" == "-" ]]; then
    input_source="/dev/stdin"
  else
    input_source="$INPUT_PATH"
  fi

  if [[ "$OUTPUT_PATH" == "-" ]]; then
    process_stream <"$input_source"
  else
    process_stream <"$input_source" >"$OUTPUT_PATH"
  fi
}

run_symbolization
