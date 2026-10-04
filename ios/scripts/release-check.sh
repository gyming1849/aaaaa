#!/bin/bash
# Release check (DESIGN §F.6; NOT part of the build gate): values that must be set before an App Store / TestFlight build.
# Exit 1 while any release blocker that can be checked from the repo is still open.
set -uo pipefail
cd "$(dirname "$0")/.."
PLIST=NutriLog/Info.plist
fail=0
val() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
problem() { echo "release-check: $1"; fail=1; }

[[ "$(val NLPrivacyPolicyURL)" == https://* ]] || problem "NLPrivacyPolicyURL must be the https URL of the privacy policy (RB-3)"
[[ "$(val NLSupportEmail)" == *@* ]] || problem "NLSupportEmail must be set: 举报 / 联系我们 (RB-5, guideline 1.2)"
[[ "$(val ITSAppUsesNonExemptEncryption)" == "false" ]] || problem "ITSAppUsesNonExemptEncryption must be NO (OS crypto only, §A.6)"
[[ "$(val NSAppTransportSecurity:NSAllowsArbitraryLoads)" == "true" ]] && problem "NSAllowsArbitraryLoads is still on: deploy HTTPS first (RB-1)"
[[ "$(val NLDefaultServerURL)" == https://* ]] || problem "NLDefaultServerURL is not https (RB-1)"

if [[ "$fail" == 0 ]]; then echo "release-check: OK"; fi
exit "$fail"
