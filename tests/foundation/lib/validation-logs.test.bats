#!/usr/bin/env bats
# A Codex validator read "Stuff the raw output into Validation.md" literally and wrote a
# Validation.md of 105 515 lines. The log stays in the file long-run.sh wrote; Validation.md names
# that file and carries the result line, the tail and every error line.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "no validator asks for the whole log in Validation.md" {
  for f in "$ROOT"/agents/*-validator.md; do
    for bad in 'Stuff the raw' 'Capture full stdout' 'Capture full output' 'Full stdout of' 'Full output of' 'Raw build/test logs are attached'; do
      ! grep -qF -- "$bad" "$f" || { echo "$(basename "$f"): $bad"; return 1; }
    done
  done
}

@test "every validator names the log file, the tail and the error lines, never the whole log" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF 'never the whole log' "$f" || { echo "$(basename "$f"): no rule"; return 1; }
    grep -qF 'the path of the log' "$f" || { echo "$(basename "$f"): no log path"; return 1; }
  done
}
