#!/usr/bin/env bash
# Count lines in Zig source files and output sorted by line count (descending).
# Used for identifying files that may need refactoring.

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

SRC_DIR="$PROJECT_ROOT/src"
TESTS_DIR="$PROJECT_ROOT/tests"
SEARCH_DIRS=("$SRC_DIR" "$TESTS_DIR")

# Find all .zig files and count lines
declare -a files
declare -a counts

while IFS= read -r file; do
  if [ -f "$file" ]; then
    line_count=$(wc -l < "$file")
    relative_path="${file#$PROJECT_ROOT/}"
    files+=("$relative_path")
    counts+=("$line_count")
  fi
done < <(find "${SEARCH_DIRS[@]}" -type f -name "*.zig" | sort)

# Check if any files were found
if [ ${#files[@]} -eq 0 ]; then
  echo "No Zig files found in src or tests directories"
  exit 0
fi

# Sort arrays by line count (descending)
# Create array of indices sorted by count
indices=()
for i in "${!counts[@]}"; do
  indices+=("$i")
done

# Bubble sort indices based on counts (descending)
for ((i = 0; i < ${#indices[@]}; i++)); do
  for ((j = i + 1; j < ${#indices[@]}; j++)); do
    if [ "${counts[${indices[$i]}]}" -lt "${counts[${indices[$j]}]}" ]; then
      # Swap indices
      tmp="${indices[$i]}"
      indices[$i]="${indices[$j]}"
      indices[$j]="$tmp"
    fi
  done
done

# Output results
printf "%-60s %10s\n" "File" "Lines"
printf "%s\n" "----------------------------------------------------------------------"

total_lines=0
for idx in "${indices[@]}"; do
  file="${files[$idx]}"
  count="${counts[$idx]}"
  total_lines=$((total_lines + count))

  # Only show files with 500+ lines
  if [ "$count" -ge 500 ]; then
    printf "%-60s %10d\n" "$file" "$count"
  fi
done

printf "%s\n" "----------------------------------------------------------------------"
printf "%-60s %10d\n" "Total" "$total_lines"
printf "\nTotal files: %d\n" "${#files[@]}"
