#!/bin/bash
# Forbidden-pattern lint for NutriLog/**/*.swift (DESIGN §A.4, §A.10). Comment-only lines are ignored.
# Exit 1 on any hit. LogicTests/ and scripts/ are not linted (the test harness prints).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=NutriLog
fail=0

# All matches of an extended regex as "path:line:text", minus comment-only lines.
matches() {
  grep -rnE --include='*.swift' -e "$1" "$ROOT" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)' || true
}

report() {
  local rule="$1" hits="$2"
  if [[ -n "$hits" ]]; then
    echo "lint: $rule"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
  fi
}

report "convertFromSnakeCase/convertToSnakeCase are forbidden: JSON keys stay verbatim" \
  "$(matches 'convert(From|To)SnakeCase')"

report "never set keyDecodingStrategy/keyEncodingStrategy" \
  "$(matches 'key(De|En)codingStrategy')"

report "AsyncImage cannot send the Bearer header: use RemotePhoto" \
  "$(matches 'AsyncImage[[:space:]]*\(')"

report "URLSession.shared is forbidden: use the APIClient's cookieless session" \
  "$(matches 'URLSession\.shared')"

report "UIApplication.shared.open must not be used for API URLs" \
  "$(matches 'UIApplication\.shared\.open' | grep -iE 'api|baseURL|serverURL|ServerConfig' || true)"

report "print/debugPrint are forbidden: use AppLog (os.Logger)" \
  "$(matches '(^|[^A-Za-z0-9_.])(print|debugPrint)[[:space:]]*\(')"

report "NumberFormatter() is only allowed inside Core/Util (use fmt / Fmt / FormatStyle)" \
  "$(matches 'NumberFormatter[[:space:]]*\(' | grep -vE '^NutriLog/Core/Util/' || true)"

report "nonisolated(unsafe) is forbidden" \
  "$(matches 'nonisolated[[:space:]]*\([[:space:]]*unsafe')"

report "Core/Models and Core/Util must not import UIKit/SwiftUI (or other UI/health frameworks)" \
  "$(matches '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(UIKit|SwiftUI|Charts|PhotosUI|HealthKit|BackgroundTasks)([[:space:]]|;|$)' \
      | grep -E '^NutriLog/Core/(Models|Util)/' || true)"

report "Core/Models may import Foundation only" \
  "$(matches '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' \
      | grep -E '^NutriLog/Core/Models/' | grep -vE ':[[:space:]]*import[[:space:]]+Foundation([[:space:]]|;|$)' || true)"

report "DispatchQueue is forbidden: use Task, Task.sleep and actors (rule A.4.9)" \
  "$(matches 'DispatchQueue')"

report "String(format:) is forbidden: use fmt / Fmt" \
  "$(matches 'String[[:space:]]*\([[:space:]]*format[[:space:]]*:')"

report "@unchecked Sendable is only allowed in Core/Util/UncheckedSendable.swift (rule A.4.6)" \
  "$(matches '@unchecked[[:space:]]+Sendable' | grep -vE '^NutriLog/Core/Util/UncheckedSendable\.swift:' || true)"

report "@preconcurrency import needs a justifying // comment on the same line (rule A.4.9)" \
  "$(matches '^[[:space:]]*@preconcurrency[[:space:]]+import' | grep -v '//' || true)"

if [[ "$fail" != 0 ]]; then
  echo "lint: FAILED"
  exit 1
fi
count="$(find "$ROOT" -name '*.swift' | wc -l | tr -d ' ')"
echo "lint: OK ($count files)"
