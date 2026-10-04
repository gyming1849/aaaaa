#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
FILES=(); while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find NutriLog -name '*.swift' -print0 | sort -z)
COMMON=(-parse-as-library -module-name NutriLog -sdk "$SDK" -target arm64-apple-ios17.0 -swift-version 6)
echo "[1/5] lint";            scripts/lint.sh
echo "[2/5] typecheck";       xcrun swiftc -typecheck "${COMMON[@]}" "${FILES[@]}"
echo "[3/5] SIL diagnostics"; xcrun swiftc -emit-sil -wmo -o /dev/null "${COMMON[@]}" "${FILES[@]}"   # Swift 6 region-isolation (data race) errors appear ONLY here
echo "[4/5] logic tests";     scripts/logic-tests.sh
if [[ "${SKIP_XCODEBUILD:-0}" != 1 ]]; then
  echo "[5/5] xcodebuild (device SDK, unsigned)"
  # XCODEBUILD_JOBS=N limits parallel build tasks (e.g. 4 on a busy machine); unset keeps xcodebuild's default.
  xcodebuild -project NutriLog.xcodeproj -scheme NutriLog -configuration Debug -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData ${XCODEBUILD_JOBS:+-jobs "$XCODEBUILD_JOBS"} \
    CODE_SIGNING_ALLOWED=NO build -quiet
fi
echo "verify: OK"
