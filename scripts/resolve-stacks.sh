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
  --toolchain-prefix STR      Prefix for cross toolchain (e.g. aarch64-linux-gnu-); applied to readelf/addr2line.
  --addr2line PATH            addr2line binary to invoke (default: value of $ADDR2LINE or 'addr2line').
  --addr2line-flags STRING    Extra flags passed verbatim to addr2line (e.g. "-f -C").
  --location-format MODE      none|short|full; default short (function + basename + line; full keeps path; none hides file:line).
  --debug                     Enable verbose debug logging to stderr (segment table, symbol hits, adjustments).
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

warn_once() {
  local key="$1" msg="$2"
  local pre_seen_mem="${WARNED_ONCE[$key]:-}"
  local pre_seen_file=0
  if [[ -f "$WARN_ONCE_FILE" ]]; then
    if grep -Fxq "$key" "$WARN_ONCE_FILE" 2>/dev/null; then
      pre_seen_file=1
    fi
  fi

  if [[ -n "$pre_seen_mem" || $pre_seen_file -eq 1 ]]; then
    return
  fi

  WARNED_ONCE["$key"]=1
  printf '%s\n' "$key" >>"$WARN_ONCE_FILE"
  warn "$msg"
}

debug_log() {
  if [[ $DEBUG_MODE -eq 1 ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

MAPS_FILE=""
SYMBOL_DIRS=()
INPUT_PATH="-"
OUTPUT_PATH="-"
ADDR2LINE_BIN="${ADDR2LINE:-addr2line}"
ADDR2LINE_FLAGS=""
TOOLCHAIN_PREFIX=""
READ_ELF_BIN="readelf"
LOCATION_FORMAT="short"
DEBUG_MODE=0

ADDR2LINE_OVERRIDDEN=0
READ_ELF_AVAILABLE=1

declare -A ADDRESS_CACHE=()
declare -A ADDRESS_RELHEX=()  # token -> relative hex for addr2line
declare -a MAP_STARTS=()    # segment starts (decimal)
declare -a MAP_ENDS=()      # segment ends (decimal)
declare -a MAP_OFFSETS=()   # file offsets
declare -a MAP_PATHS=()     # module paths from maps
declare -a MAP_ADJUSTS=()   # start - offset
declare -a RESOLVED_SYMBOL_DIRS=()
declare -A BINARY_CACHE=()      # module_path -> binary path (or sentinel)
declare -A ADDRESS_META=()      # token -> READY/UNRESOLVABLE
declare -A ADDRESS_SEGMENT=()   # token -> segment index
declare -A ADDRESS_BINARY=()    # token -> binary path
declare -A ADDRESS_MODULE=()    # token -> module path
declare -A MODULE_TYPES=()      # binary path -> ELF type
declare -A MODULE_BLOCKED=()    # module path -> blocked (missing symbols)
declare -A WARNED_ONCE=()       # dedupe warnings per key
WARN_ONCE_FILE=""
declare -a ADDR2LINE_BASE=()    # prebuilt addr2line argv prefix
declare -A MODULE_HIT_SEEN=()   # module path -> seen as hit
declare -A MODULE_MISS_SEEN=()  # module path -> seen as miss

MODULE_RESOLVE_HITS=0
MODULE_RESOLVE_MISS=0
ADDR2LINE_SKIPPED=0

LINES_PROCESSED=0
BATCH_CALLS=0

SYMBOL_SEARCH_AVAILABLE=0
readonly MISSING_BINARY_SENTINEL="__MISSING_BINARY__"
readonly UNRESOLVABLE_SENTINEL="__UNRESOLVABLE__"

# Initialize warn-once file early so pre-run_symbolization warnings do not fail
WARN_ONCE_FILE=$(mktemp 2>/dev/null || printf '/tmp/resolve-stacks.warnonce.$$')
touch "$WARN_ONCE_FILE" 2>/dev/null || true
trap 'rm -f "$WARN_ONCE_FILE"' EXIT

prepare_addr2line_base() {
  ADDR2LINE_BASE=("$ADDR2LINE_BIN" "-f" "-C")
  if [[ -n "$ADDR2LINE_FLAGS" ]]; then
    local extra_flags=()
    read -r -a extra_flags <<< "$ADDR2LINE_FLAGS"
    if [[ ${#extra_flags[@]} -gt 0 ]]; then
      ADDR2LINE_BASE+=("${extra_flags[@]}")
    fi
  fi
}


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
    if [[ $DEBUG_MODE -eq 1 ]]; then
      local dir
      for dir in "${RESOLVED_SYMBOL_DIRS[@]}"; do
        debug_log "symbol-dir resolved: $dir"
      done
    fi
  fi
}

load_maps() {
  # Parse maps file into parallel arrays for fast segment lookup.
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

      debug_log "maps segment start=0x$(printf '%x' "$start_dec") end=0x$(printf '%x' "$end_dec") offset=0x$(printf '%x' "$offset_dec") path=$path adjust=0x$(printf '%x' "$adjust")"
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
    warn_once "NOSYMDIR::$module_path" "No symbol directories available to resolve $module_path"
    return 1
  fi

  local sanitized="${module_path#/}"
  local module_basename="${module_path##*/}"
  if [[ -z "$module_basename" ]]; then
    module_basename="$sanitized"
  fi

  local dir candidate

  # 1) 根平铺：目录根直接按文件名查找
  for dir in "${RESOLVED_SYMBOL_DIRS[@]}"; do
    candidate="${dir%/}/${module_basename}"
    if [[ -f "$candidate" ]]; then
      BINARY_CACHE["$module_path"]="$candidate"
      if [[ -z "${MODULE_HIT_SEEN[$module_path]:-}" ]]; then
        MODULE_HIT_SEEN["$module_path"]=1
        ((++MODULE_RESOLVE_HITS))
      fi
      debug_log "module $module_path resolved to $candidate via root-flat"
      printf '%s' "$candidate"
      return 0
    fi
  done

  # 2) sysroot 拼接：使用 maps 原始绝对路径
  for dir in "${RESOLVED_SYMBOL_DIRS[@]}"; do
    candidate="${dir%/}/${sanitized}"
    if [[ -f "$candidate" ]]; then
      BINARY_CACHE["$module_path"]="$candidate"
      if [[ -z "${MODULE_HIT_SEEN[$module_path]:-}" ]]; then
        MODULE_HIT_SEEN["$module_path"]=1
        ((++MODULE_RESOLVE_HITS))
      fi
      debug_log "module $module_path resolved to $candidate via sysroot path"
      printf '%s' "$candidate"
      return 0
    fi
  done

  # 3) basename 回退：在目录下递归按文件名查找
  for dir in "${RESOLVED_SYMBOL_DIRS[@]}"; do
    candidate=$(find "$dir" -type f -name "$module_basename" -print -quit 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      BINARY_CACHE["$module_path"]="$candidate"
      if [[ -z "${MODULE_HIT_SEEN[$module_path]:-}" ]]; then
        MODULE_HIT_SEEN["$module_path"]=1
        ((++MODULE_RESOLVE_HITS))
      fi
      debug_log "module $module_path resolved to $candidate via basename search"
      printf '%s' "$candidate"
      return 0
    fi
  done

  BINARY_CACHE["$module_path"]="$MISSING_BINARY_SENTINEL"
  if [[ -z "${MODULE_MISS_SEEN[$module_path]:-}" ]]; then
    MODULE_MISS_SEEN["$module_path"]=1
    ((++MODULE_RESOLVE_MISS))
  fi
  warn_once "MISSBIN::$module_path" "missing binary for $module_path"
  return 1
}

detect_elf_type() {
  # Use readelf to choose between ET_EXEC (no adjust) and ET_DYN (apply adjust); cache per binary.
  local binary="$1"
  local cached="${MODULE_TYPES[$binary]:-}"
  if [[ -n "$cached" ]]; then
    printf '%s' "$cached"
    return 0
  fi

  if [[ $READ_ELF_AVAILABLE -eq 0 ]]; then
    MODULE_TYPES["$binary"]="UNKNOWN"
    printf '%s' "UNKNOWN"
    return 0
  fi

  local header
  if ! header=$("$READ_ELF_BIN" -h "$binary" 2>/dev/null); then
    MODULE_TYPES["$binary"]="UNKNOWN"
    debug_log "readelf failed for $binary; treating type as UNKNOWN"
    printf '%s' "UNKNOWN"
    return 0
  fi

  local type_line="" line type
  while IFS= read -r line; do
    if [[ "$line" == *Type:* ]]; then
      type_line="$line"
      break
    fi
  done <<< "$header"
  if [[ "$type_line" == *EXEC* ]]; then
    type="ET_EXEC"
  elif [[ "$type_line" == *DYN* ]]; then
    type="ET_DYN"
  else
    type="UNKNOWN"
  fi

  MODULE_TYPES["$binary"]="$type"
  printf '%s' "$type"
}

render_symbol() {
  # Format function + source according to location-format (none|short|full).
  local func="$1" src="$2"
  case "$LOCATION_FORMAT" in
    none)
      printf '%s' "$func"
      ;;
    short)
      local file="${src%%:*}"
      local line="${src##*:}"
      if [[ -z "$file" || "$file" == "??" ]]; then
        printf '%s' "$func"
      else
        file="${file##*/}"
        printf '%s (%s:%s)' "$func" "$file" "$line"
      fi
      ;;
    full)
      local file="${src%%:*}"
      local line="${src##*:}"
      if [[ -z "$file" || "$file" == "??" ]]; then
        printf '%s' "$func"
      else
        printf '%s (%s:%s)' "$func" "$file" "$line"
      fi
      ;;
  esac
}

prepare_address_metadata() {
  # Derive module/binary for a raw address; cache status to avoid repeat work.
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

  if [[ -n "${MODULE_BLOCKED[$module_path]:-}" ]]; then
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  local binary_path
  if ! binary_path=$(locate_binary_for_module "$module_path"); then
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  debug_log "address $token -> module $module_path binary $binary_path"

  ADDRESS_SEGMENT["$token"]="$segment_idx"
  ADDRESS_BINARY["$token"]="$binary_path"
  ADDRESS_MODULE["$token"]="$module_path"
  ADDRESS_META["$token"]="READY"
  return 0
}

compute_rel_hex_for_token() {
  # Compute relative hex address for addr2line based on ELF type; caches per token.
  local token="$1"
  local status="${ADDRESS_META[$token]:-}"
  if [[ "$status" != "READY" ]]; then
    return 1
  fi

  if [[ -n "${ADDRESS_RELHEX[$token]:-}" ]]; then
    return 0
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
  local rel_dec rel_hex elf_type

  elf_type=$(detect_elf_type "$binary_path")
  if [[ "$elf_type" == "ET_EXEC" ]]; then
    rel_dec=$addr_dec
    printf -v rel_hex "0x%x" "$rel_dec"
  else
    rel_dec=$((addr_dec - adjust))
    if (( rel_dec < 0 )); then
      warn "address $token yielded negative relative offset for $module_path"
      ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
      return 1
    fi
    printf -v rel_hex "0x%x" "$rel_dec"
  fi

  debug_log "addr $token module=$module_path binary=$binary_path rel=$rel_hex"
  ADDRESS_RELHEX["$token"]="$rel_hex"
  return 0
}

symbolize_address() {
  # Turn a hex address into symbol text; respects ELF type and location-format.
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

  local elf_type rel_hex
  if ! compute_rel_hex_for_token "$token"; then
    return 1
  fi
  rel_hex="${ADDRESS_RELHEX[$token]}"
  elf_type="${MODULE_TYPES[$binary_path]:-UNKNOWN}"
  debug_log "addr $token module=$module_path binary=$binary_path elf=$elf_type rel=$rel_hex"

  local cmd=("${ADDR2LINE_BASE[@]}")
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

  if [[ "$func" == "??" || "$src" == "??:0" || "$src" == "??" ]]; then
    MODULE_BLOCKED["$module_path"]=1
    warn_once "NOSYMBOL::$module_path" "missing symbols for $module_path; keeping raw addresses"
    ((++ADDR2LINE_SKIPPED))
    ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
    return 1
  fi

  local pretty
  pretty=$(render_symbol "$func" "$src")
  debug_log "addr $token resolved to $pretty"
  printf '%s' "$pretty"
}

resolve_frame_token() {
  # Resolve a single frame token; non-hex tokens pass through unchanged.
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

symbolize_batch_for_binary() {
  # Batch symbolize multiple addresses for the same binary in one addr2line call.
  local binary="$1"
  local tokens_str="$2"
  local rels_str="$3"

  local -a tokens=()
  local -a rels=()
  read -r -a tokens <<< "$tokens_str"
  read -r -a rels <<< "$rels_str"
  if [[ ${#tokens[@]} -eq 0 ]]; then
    return
  fi

  ((++BATCH_CALLS))
  debug_log "batch addr2line binary=$binary count=${#tokens[@]}"

  local cmd=("${ADDR2LINE_BASE[@]}")
  cmd+=("-e" "$binary")
  cmd+=("${rels[@]}")

  local -a lines=()
  if ! mapfile -t lines < <("${cmd[@]}" 2>/dev/null); then
    warn "addr2line batch failed for $binary"
    for token in "${tokens[@]}"; do
      if symbol=$(symbolize_address "$token"); then
        ADDRESS_CACHE["$token"]="$symbol"
      else
        ADDRESS_CACHE["$token"]="$token"
      fi
    done
    return
  fi

  local expected=$(( ${#tokens[@]} * 2 ))
  if (( ${#lines[@]} < expected )); then
    debug_log "addr2line batch output mismatch for $binary (got ${#lines[@]}, expected $expected); falling back"
    for token in "${tokens[@]}"; do
      if symbol=$(symbolize_address "$token"); then
        ADDRESS_CACHE["$token"]="$symbol"
      else
        ADDRESS_CACHE["$token"]="$token"
      fi
    done
    return
  fi

  local idx token func src module_path pretty
  for idx in "${!tokens[@]}"; do
    token="${tokens[$idx]}"
    func="${lines[$((idx*2))]:-??}"
    src="${lines[$((idx*2+1))]:-??:0}"
    module_path="${ADDRESS_MODULE[$token]:-}"
    if [[ -z "$func" ]]; then func="??"; fi
    if [[ -z "$src" ]]; then src="??:0"; fi

    if [[ "$func" == "??" || "$src" == "??:0" || "$src" == "??" ]]; then
      if [[ -n "$module_path" ]]; then
        MODULE_BLOCKED["$module_path"]=1
        warn_once "NOSYMBOL::$module_path" "missing symbols for $module_path; keeping raw addresses"
      fi
      ((++ADDR2LINE_SKIPPED))
      ADDRESS_META["$token"]="$UNRESOLVABLE_SENTINEL"
      ADDRESS_CACHE["$token"]="$token"
      continue
    fi

    pretty=$(render_symbol "$func" "$src")
    ADDRESS_CACHE["$token"]="$pretty"
  done
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

  ((++LINES_PROCESSED))
  if [[ $DEBUG_MODE -eq 1 && $((LINES_PROCESSED % 1000)) -eq 0 ]]; then
    debug_log "progress lines=$LINES_PROCESSED batches=$BATCH_CALLS"
  fi

  IFS=';' read -r -a frames <<< "$stack_part"

  declare -A batch_tokens=()
  declare -A batch_rels=()

  local idx frame binary token
  for idx in "${!frames[@]}"; do
    frame="$(trim_whitespace "${frames[$idx]}")"

    if [[ -n "${ADDRESS_CACHE[$frame]:-}" ]]; then
      frames[$idx]="${ADDRESS_CACHE[$frame]}"
      continue
    fi

    if ! is_hex_address "$frame"; then
      ADDRESS_CACHE["$frame"]="$frame"
      frames[$idx]="$frame"
      continue
    fi

    if ! prepare_address_metadata "$frame"; then
      ADDRESS_CACHE["$frame"]="$frame"
      frames[$idx]="$frame"
      continue
    fi

    if ! compute_rel_hex_for_token "$frame"; then
      ADDRESS_CACHE["$frame"]="$frame"
      frames[$idx]="$frame"
      continue
    fi

    binary="${ADDRESS_BINARY[$frame]}"
    if [[ -n "${batch_tokens[$binary]+set}" ]]; then
      batch_tokens["$binary"]+=" $frame"
    else
      batch_tokens["$binary"]="$frame"
    fi

    if [[ -n "${batch_rels[$binary]+set}" ]]; then
      batch_rels["$binary"]+=" ${ADDRESS_RELHEX[$frame]}"
    else
      batch_rels["$binary"]="${ADDRESS_RELHEX[$frame]}"
    fi
    frames[$idx]="$frame"
  done

  local bin
  for bin in "${!batch_tokens[@]}"; do
    symbolize_batch_for_binary "$bin" "${batch_tokens[$bin]}" "${batch_rels[$bin]}"
  done

  for idx in "${!frames[@]}"; do
    token="${frames[$idx]}"
    if [[ -n "${ADDRESS_CACHE[$token]:-}" ]]; then
      frames[$idx]="${ADDRESS_CACHE[$token]}"
    fi
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
      ADDR2LINE_OVERRIDDEN=1
      ;;
    --addr2line-flags)
      shift || abort "--addr2line-flags requires a string"
      ADDR2LINE_FLAGS="$1"
      ;;
    --toolchain-prefix)
      shift || abort "--toolchain-prefix requires a prefix"
      TOOLCHAIN_PREFIX="$1"
      ;;
    --location-format)
      shift || abort "--location-format requires a mode (none|short|full)"
      LOCATION_FORMAT="$1"
      ;;
    --debug)
      DEBUG_MODE=1
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

case "$LOCATION_FORMAT" in
  none|short|full) ;;
  *) abort "Invalid --location-format: $LOCATION_FORMAT (expected none|short|full)" ;;
esac

if [[ -n "$TOOLCHAIN_PREFIX" ]]; then
  READ_ELF_BIN="${TOOLCHAIN_PREFIX}readelf"
  if [[ $ADDR2LINE_OVERRIDDEN -eq 0 ]]; then
    ADDR2LINE_BIN="${TOOLCHAIN_PREFIX}addr2line"
  fi
fi

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

if [[ "$INPUT_PATH" != "-" && "$OUTPUT_PATH" != "-" ]]; then
  abs_in=$(cd "$(dirname "$INPUT_PATH")" && pwd -P)/"$(basename "$INPUT_PATH")"
  abs_out=$(cd "$(dirname "$OUTPUT_PATH")" && pwd -P)/"$(basename "$OUTPUT_PATH")"
  if [[ "$abs_in" == "$abs_out" ]]; then
    abort "Input and output paths are identical; use distinct files to avoid overwrite"
  fi
fi

if ! command -v "$ADDR2LINE_BIN" >/dev/null 2>&1; then
  abort "addr2line binary not found: $ADDR2LINE_BIN"
fi

# Build addr2line base argv once for reuse in batch/single calls
prepare_addr2line_base

if ! command -v "$READ_ELF_BIN" >/dev/null 2>&1; then
  READ_ELF_AVAILABLE=0
  warn_once "READ_ELF_MISSING" "readelf not found (${READ_ELF_BIN}); ELF 类型将视为未知并使用相对地址策略"
else
  READ_ELF_AVAILABLE=1
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

  if [[ $DEBUG_MODE -eq 1 ]]; then
    debug_log "summary lines=$LINES_PROCESSED batches=$BATCH_CALLS modules_hit=$MODULE_RESOLVE_HITS modules_miss=$MODULE_RESOLVE_MISS addr2line_skipped=$ADDR2LINE_SKIPPED"
  fi
}

run_symbolization
