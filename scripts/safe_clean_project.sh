#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/safe_clean_project.sh --dry-run
  ./scripts/safe_clean_project.sh --apply

Default mode: --dry-run
EOF
}

human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" '
    function fmt(x, i, units) {
      units[1]="B"; units[2]="KB"; units[3]="MB"; units[4]="GB"; units[5]="TB";
      i=1;
      while (x >= 1024 && i < 5) { x /= 1024; i++; }
      return (i == 1) ? sprintf("%d %s", x, units[i]) : sprintf("%.2f %s", x, units[i]);
    }
    BEGIN { print fmt(b); }
  '
}

project_size_kb() {
  du -sk "$1" | awk '{print $1}'
}

MODE="${1:---dry-run}"
case "$MODE" in
  --dry-run|--apply) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac

ROOT="$(pwd -P)"
LIST_FILE="$(mktemp)"
FILTERED_LIST_FILE="$(mktemp)"
trap 'rm -f "$LIST_FILE" "$FILTERED_LIST_FILE"' EXIT

find "$ROOT" \
  \( -path "$ROOT/.git" -o -path "$ROOT/.git/*" \) -prune -o \
  \( \
    -type d \( \
      -name node_modules -o -name dist -o -name build -o -name .cache -o -name tmp -o -name .tmp -o \
      -name .build -o -name DerivedData -o -name xcuserdata -o \
      -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o \
      -name target -o -name bin -o -name pkg -o \
      -name CMakeFiles -o \
      -name .codex -o -name .agent \
    \) \
    -o \
    -type f \( -name "*.log" -o -name ".DS_Store" -o -name "*.xcuserstate" -o -name "*.pyc" -o -name "CMakeCache.txt" \) \
  \) -print0 > "$LIST_FILE"

# Remove nested entries when a parent directory is already selected.
# This prevents double counting and duplicate deletion targets.
while IFS= read -r -d '' path; do
  skip=0
  while IFS= read -r -d '' parent; do
    case "$path" in
      "$parent"/*)
        skip=1
        break
        ;;
    esac
  done < "$FILTERED_LIST_FILE"

  if [[ "$skip" -eq 0 ]]; then
    printf '%s\0' "$path" >> "$FILTERED_LIST_FILE"
  fi
done < "$LIST_FILE"

mv "$FILTERED_LIST_FILE" "$LIST_FILE"

before_kb="$(project_size_kb "$ROOT")"
before_bytes=$((before_kb * 1024))

echo "Project root: $ROOT"
echo "Project size: $(human_size "$before_bytes")"
echo
echo "Candidates for deletion:"

count=0
delete_kb=0
while IFS= read -r -d '' path; do
  count=$((count + 1))
  size_kb="$(du -sk "$path" | awk '{print $1}')"
  delete_kb=$((delete_kb + size_kb))
  rel="${path#$ROOT/}"
  [[ "$rel" == "$path" ]] && rel="$path"
  echo " - $rel ($(human_size $((size_kb * 1024))))"
done < "$LIST_FILE"

if [[ "$count" -eq 0 ]]; then
  echo " - Nothing to delete."
fi

echo
echo "Total to delete: $(human_size $((delete_kb * 1024)))"

if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "Dry-run complete. No files were deleted."
  exit 0
fi

echo
read -r -p "Confirm deletion of listed items? [y/N] " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *)
    echo "Canceled. No files were deleted."
    exit 0
    ;;
esac

while IFS= read -r -d '' path; do
  case "$path" in
    "$ROOT"/*) ;;
    *)
      echo "Skip outside project: $path"
      continue
      ;;
  esac

  if [[ -d "$path" ]]; then
    rm -rf "$path"
  elif [[ -f "$path" ]]; then
    rm -f "$path"
  fi
done < "$LIST_FILE"

after_kb="$(project_size_kb "$ROOT")"
after_bytes=$((after_kb * 1024))
freed_bytes=$((before_bytes - after_bytes))
if [[ "$freed_bytes" -lt 0 ]]; then
  freed_bytes=0
fi

echo
echo "Cleanup complete."
echo "New project size: $(human_size "$after_bytes")"
echo "Freed space: $(human_size "$freed_bytes")"
