#!/bin/bash
# POSTs request bodies ENCODED BY THE SWIFT REQUEST TYPES to the LOCAL server and records the responses as fixtures
# `swift_*.json` (decoded again by the Live suite). Run after collect.sh, against the same server:
#   LogicTests/Live/post-swift.sh          # BASE defaults to http://127.0.0.1:8790
#
# The Live binary in emit mode (LIVE_EMIT_DIR) builds every body from the decoded fixtures, as the app does (meal items from
# the AI draft, FoodInput(draft:), Food.toInput(), Profile from /auth/me, a HealthSyncRequest from SyncDay/SyncSample/
# SyncWorkout …). Each POST must answer 2xx; the HealthKit batch must also give sensible per-item results and store the
# exact values; full-replace round trips (PUT profile / settings / foods) must not change what the server stores.
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE="${BASE:-http://127.0.0.1:8790}"
case "$BASE" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "post-swift.sh: refusing to write to a non-local server ($BASE)"; exit 2 ;;
esac
API="$BASE/api/v1"
FIX="LogicTests/Live/fixtures"
WORK="build/qa/work"
BODIES="build/qa/swift-bodies"
mkdir -p "$WORK" "$BODIES"
FAILS=0

# ---------------------------------------------------------------- build the Live binary (same command as logic-tests.sh)

SOURCES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"; line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$line" ]] && SOURCES+=("$line")
done < LogicTests/Live/sources.txt
echo "[build] Live suite"
nice -n 10 xcrun swiftc -swift-version 6 -module-name LogicTests LogicTests/Harness.swift "${SOURCES[@]}" LogicTests/Live/main.swift -o build/logic-Live

# ---------------------------------------------------------------- helpers

TOKEN="$(curl -sS "$API/auth/token" -H 'Content-Type: application/json' -d '{"username":"demo","password":"demo123","device_name":"QA Swift"}' | jq -r .token)"
[[ "$TOKEN" == nla_* ]] || { echo "login failed"; exit 1; }
LAST=""

# send NAME METHOD PATH BODYFILE|-  → saves fixture swift_NAME (NAME "-" = don't save)
send() {
  local name="$1" method="$2" path="$3" file="${4:--}"
  local args=(-sS -o "$WORK/resp.json" -w '%{http_code}' -X "$method" "$API/$path" -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json')
  if [[ "$method" != GET && "$method" != DELETE ]]; then
    if [[ "$file" == - ]]; then args+=(-H 'Content-Type: application/json' --data-binary '{}')
    else args+=(-H 'Content-Type: application/json' --data-binary "@$file"); fi
  fi
  local code; code="$(curl "${args[@]}")"
  LAST="$(cat "$WORK/resp.json")"
  if [[ "$code" != 2* ]]; then
    echo "FAIL $method $path (Swift body ${file##*/}) → $code: $LAST"
    FAILS=$((FAILS + 1)); return 0
  fi
  [[ "$name" == - ]] || cp "$WORK/resp.json" "$FIX/swift_$name.json"
  printf '  %-30s %s %s → %s\n' "${name}" "$method" "$path" "$code"
}

# expect DESCRIPTION JQ_FILTER  → jq -e on LAST; the filter can read $before (the JSON in BEFORE)
BEFORE=null
expect() {
  local desc="$1" filter="$2"
  if jq -e --argjson before "$BEFORE" "$filter" >/dev/null <<<"$LAST"; then echo "    ok   $desc"
  else echo "    FAIL $desc  ($filter)"; FAILS=$((FAILS + 1)); fi
}

send - GET auth/me
TODAY="$(jq -r .today <<<"$LAST")"
ME_BEFORE="$LAST"
day() { python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])+datetime.timedelta(days=int(sys.argv[2]))).isoformat())" "$TODAY" "$1"; }
echo "[emit] Swift-encoded bodies (today=$TODAY)"
rm -f "$BODIES"/*.json
LIVE_EMIT_DIR="$BODIES" LIVE_TODAY="$TODAY" build/logic-Live
B() { echo "$BODIES/$1.json"; }

# ---------------------------------------------------------------- HealthKit batch built from SyncDay / SyncSample / SyncWorkout

echo "[health/sync] Swift HealthSyncRequest"
# Start from no HealthKit data (local QA server only) so the per-item counts below are exact on every run.
printf '{"device_id":"swift-live-0001","delete_data":true}' > "$WORK/reset.json"
send - POST health/sync/unlink "$WORK/reset.json"
jq -c '{device_id, days: (.days|length), samples: [.samples[].type], workouts: [.workouts[].activity_key], deleted}' "$(B health_sync)"
send health_sync POST health/sync "$(B health_sync)"
expect "ok, no timezone mismatch" '.ok == true and .timezone_mismatch == false'
expect "3 days stored, none rejected" '(.days.upserted + .days.unchanged) == 3 and (.days.rejected | length) == 0'
expect "4 samples inserted, none rejected" '.samples.inserted == 4 and (.samples.rejected | length) == 0'
expect "2 workouts inserted, none rejected" '.workouts.inserted == 2 and (.workouts.rejected | length) == 0'
expect "unknown deletion reported as not_found" '.deleted.not_found == 1 and .deleted.body == 0 and .deleted.exercises == 0'
expect "invalidated_from = earliest date" ".invalidated_from == \"$(day -4)\""
send health_sync_resend POST health/sync "$(B health_sync)"
expect "resend is idempotent" '.days.upserted == 0 and .samples.unchanged == 4 and .workouts.unchanged == 2 and .invalidated_from == null'
send health_sync_state GET health/sync/state
expect "device + kinds recorded" '.devices[] | select(.device_id == "swift-live-0001") | (.device_name == "Swift Live iPhone") and (.kinds | keys == ["days","samples","workouts"])'
send body_rows GET "body?start=$(day -4)&end=$TODAY"
expect "body_mass stored" '.[] | select(.external_id == "5E1F0000-0000-4000-8000-000000000001") | .weight_kg == 80.9 and .source == "healthkit" and .source_name == "健康" and .time == "07:05"'
expect "body_fat stored" '.[] | select(.external_id == "5E1F0000-0000-4000-8000-000000000002") | .body_fat_pct == 21.9'
expect "waist stored" '.[] | select(.external_id == "5E1F0000-0000-4000-8000-000000000003") | .waist_cm == 86.5'
expect "blood pressure stored, bp_treated → 1" '.[] | select(.external_id == "5E1F0000-0000-4000-8000-000000000004") | .sbp == 131 and .dbp == 84 and .bp_treated == 1'
send activity GET "activity?start=$(day -4)&end=$TODAY"
expect "run workout stored verbatim" ".exercises[] | select(.external_id == \"5E1F0000-0000-4000-8000-0000000000A1\") | .duration_min == 42.3 and .met == 9.6 and .avg_hr == 151 and .device_kcal == 455.2 and .in_device == 1 and .hk_activity_type == 37 and .started_at == \"$(day -2)T06:40:00+08:00\" and .activity_key == \"run_10kmh\""
expect "nil MET → table MET" '.exercises[] | select(.external_id == "5E1F0000-0000-4000-8000-0000000000A2") | .met > 0 and .activity_key == "cycle_stationary" and .distance_km == null'
expect "day totals stored (clear → null)" ".days[] | select(.date == \"$(day -2)\") | .steps == 12006 and .sleep_hours == 7.5 and .stand_hours == null"
expect "day totals stored" ".days[] | select(.date == \"$(day -4)\") | .steps == 7421 and .resting_kcal == 1702.4 and .sleep_hours == 6.92"

# ---------------------------------------------------------------- meals / preview / water

echo "[meals]"
send meal_ai POST ai/meal "$(B meal_ai)"
send meal POST meals "$(B meal)"
MEAL_ID="$(jq -r .id <<<"$LAST")"
send meal_update PUT "meals/$MEAL_ID" "$(B meal_update)"
send preview POST preview "$(B preview)"
expect "preview adds the meal" '.after.mealCount == .before.mealCount + 1'
send water POST water "$(B water)"

# ---------------------------------------------------------------- activity / body / labs / exercises

echo "[activity/body]"
send activity_ai POST ai/activity "$(B activity_ai)"
send activity_commit POST activity/commit "$(B activity_commit)"
expect "commit stored the workouts" ".workouts == $(jq '.workouts | length' "$(B activity_commit)")"
send body POST body "$(B body)"
send labs POST labs "$(B labs)"
send exercise POST exercises "$(B exercise)"
EX_ID="$(jq -r .id <<<"$LAST")"
send in_device PATCH "exercises/$EX_ID" "$(B in_device)"
send activity_put PUT "activity/$(day -5)" "$(B activity_put)"
send - GET "activity?start=$(day -5)&end=$(day -5)"
expect "PUT activity stored, nil fields cleared" '.days[0] | .steps == 6500 and .distance_km == 4.1 and .resting_kcal == null and .source == "manual"'

# ---------------------------------------------------------------- foods

echo "[foods]"
send food_ai POST ai/food "$(B food_ai)"
send food POST foods "$(B food)"
FOOD_ID="$(jq -r .id <<<"$LAST")"
send - GET "foods/$FOOD_ID"
expect "FoodInput(draft:) stored name/aliases/per100" "(.name == $(jq '.name' "$(B food)")) and (.per100 | length) == 43"
send - GET foods/1
BEFORE="$LAST"
send food_update_seed_roundtrip PUT foods/1 "$(B food_update_seed_roundtrip)"
send - GET foods/1
# "" and null are equivalent for brand / serving_desc / ingredients / notes (meals §1.12); toInput() sends "".
expect "Food.toInput() round trip changes nothing" 'def norm: del(.updated_at) | (.brand, .serving_desc, .ingredients, .notes) |= (. // ""); (norm) == ($before | norm)'
send from_item POST foods/from-item "$(B from_item)"
send food_item POST "foods/$FOOD_ID/item" "$(B food_item)"
expect "foods/{id}/item grams" '.amount_g == 180'
send food_item_default POST "foods/$FOOD_ID/item" "$(B food_item_default)"
expect "foods/{id}/item default = serving_g" ".amount_g == $(jq '.serving_g' "$(B food)")"

# ---------------------------------------------------------------- profile / settings / reports / unlink

echo "[account]"
send profile PUT profile "$(B profile)"
BEFORE="$ME_BEFORE"
expect "PUT profile round trip changes nothing" '.profile == $before.profile'
send settings PUT settings "$(B settings)"
send - GET auth/me
expect "PUT settings round trip changes nothing" '.user == $before.user'
send period_summary POST period/summary "$(B period_summary)"
send unlink POST health/sync/unlink "$(B unlink)"
expect "unlink without data deletes nothing" '.ok and .deleted.body == 0 and .deleted.exercises == 0 and .deleted.days == 0'
send day GET "day/$TODAY"
expect "Swift meal update visible on the day" '[.meals[] | select(.description == "Swift 编码的早餐（改）")] | length >= 1'

echo
if [[ $FAILS -gt 0 ]]; then echo "post-swift.sh: $FAILS FAILED"; exit 1; fi
echo "post-swift.sh: every Swift-encoded body accepted; fixtures swift_*.json written"
