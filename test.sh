#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift run CodexUsageOverlay --self-test
swift run CodexUsageOverlay --print-usage
if swift run CodexUsageOverlay --inspect-placement; then
  :
else
  placement_status=$?
  if [ "$placement_status" -eq 4 ]; then
    echo "live placement check skipped: the composer may be unavailable while Codex is responding" >&2
  else
    exit "$placement_status"
  fi
fi
