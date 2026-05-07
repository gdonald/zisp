#!/usr/bin/env bash
# Find tests in src/ files that should be moved to tests/ directory.
#
# This script scans Zig source files in src/ and identifies test blocks
# (`test "name" { ... }` or bare `test { ... }`) that should live under
# tests/ instead. Per the project guideline (tests/all.zig): implementation
# modules under src/ contain no test blocks.

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Check if src directory exists
SRC_DIR="$PROJECT_ROOT/src"
if [ ! -d "$SRC_DIR" ]; then
  echo "Error: src directory not found"
  exit 1
fi

# Print header
echo "================================================================================"
echo "MISPLACED TESTS REPORT"
echo "================================================================================"
echo ""
echo "According to project guidelines, tests should be in tests/ directory,"
echo "not in implementation files."
echo ""

total_tests=0
files_with_tests=0
declare -a files_info

# A Zig top-level test block looks like:
#   test "name" { ... }
#   test { ... }
# Top-level tests start at column 0 with the keyword `test` followed by either
# a string literal or `{`. We anchor on `^test ` / `^test\b` to avoid matching
# identifiers that happen to contain "test".
TEST_PATTERN='^test[[:space:]]*("[^"]*"[[:space:]]*\{|\{)'

while IFS= read -r file; do
  if [ ! -f "$file" ]; then
    continue
  fi

  # Count test blocks in this file.
  test_count=$(grep -cE "$TEST_PATTERN" "$file" || true)

  if [ "$test_count" -eq 0 ]; then
    continue
  fi

  # Extract test names (the quoted strings on `test "..."` lines). Bare
  # anonymous `test {` blocks have no name; report them as "<anonymous>".
  test_names=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^test[[:space:]]*\"([^\"]*)\" ]]; then
      test_names+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^test[[:space:]]*\{ ]]; then
      test_names+=("<anonymous>")
    fi
  done < <(grep -E "$TEST_PATTERN" "$file" || true)

  # Store file info
  relative_path="${file#$PROJECT_ROOT/}"
  files_info+=("$relative_path|$test_count|${test_names[*]}")

  total_tests=$((total_tests + test_count))
  files_with_tests=$((files_with_tests + 1))

done < <(find "$SRC_DIR" -type f -name "*.zig" | sort)

# Output results
if [ "$files_with_tests" -gt 0 ]; then
  echo "Found $files_with_tests files with tests ($total_tests total tests):"
  echo ""

  for info in "${files_info[@]}"; do
    IFS='|' read -r file_path test_count test_names_str <<< "$info"

    echo "$file_path"
    echo "   Tests: $test_count"

    if [ -n "$test_names_str" ]; then
      echo "   Names:"
      read -ra test_names <<< "$test_names_str"
      count=0
      for name in "${test_names[@]}"; do
        if [ "$count" -lt 5 ]; then
          echo "     - $name"
          count=$((count + 1))
        fi
      done

      if [ "${#test_names[@]}" -gt 5 ]; then
        remaining=$((${#test_names[@]} - 5))
        echo "     ... and $remaining more"
      fi
    fi
    echo ""
  done
  echo "================================================================================"
  echo "Summary: $total_tests tests in $files_with_tests files"
  echo "================================================================================"
  exit 1
else
  echo "No test blocks found in src/ — all tests are properly placed."
  echo "================================================================================"
fi
