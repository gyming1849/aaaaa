#!/bin/bash
# Records REAL server responses as fixtures for the Live logic-test suite (LogicTests/Live/main.swift).
#
# Run it against a LOCAL, freshly seeded server only (it writes: meals, foods, body, labs, settings, health sync …):
#   rm -rf build/qa/data && (cd .. && DATA_DIR=$PWD/ios/build/qa/data npm run seed:demo -w server)
#   (cd ../server && DATA_DIR=… PORT=8790 AI_PROVIDER=mock SCHEDULER=false WEEKLY_AI_SUMMARY=false npx tsx src/index.ts &)
#   LogicTests/Live/collect.sh                       # BASE defaults to http://127.0.0.1:8790
#
# Every response body is saved verbatim (only token strings are redacted) to LogicTests/Live/fixtures/<name>.json.
# Request bodies mirror what the Swift request types encode (keys verbatim); `post-swift.sh` then re-posts bodies that
# the Swift types themselves encoded.
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE="${BASE:-http://127.0.0.1:8790}"
case "$BASE" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "collect.sh: refusing to write to a non-local server ($BASE)"; exit 2 ;;
esac
API="$BASE/api/v1"
FIX="LogicTests/Live/fixtures"
WORK="build/qa/work"
mkdir -p "$FIX" "$WORK"
PHOTO="$WORK/photo.jpg"
if [[ ! -f "$PHOTO" ]]; then
  sips -s format jpeg -s formatOptions 60 -Z 160 NutriLog/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png --out "$PHOTO" >/dev/null
fi

# ---------------------------------------------------------------- helpers

LAST=""   # body of the last response

# call NAME METHOD PATH [JSON_BODY] [TOKEN]  → saves fixture NAME (unless NAME is "-"), fails on non-2xx
call() {
  local name="$1" method="$2" path="$3" body="${4:-}" tok="${5:-${TOKEN:-}}"
  local args=(-sS -o "$WORK/resp.json" -w '%{http_code}' -X "$method" "$API/$path" -H 'Accept: application/json')
  [[ -n "$tok" ]] && args+=(-H "Authorization: Bearer $tok")
  if [[ "$method" != GET && "$method" != DELETE ]]; then
    [[ -n "$body" ]] || body='{}'
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  local code
  code="$(curl "${args[@]}")"
  LAST="$(cat "$WORK/resp.json")"
  if [[ "$code" != 2* ]]; then
    echo "FAIL $method $path → $code: $LAST" >&2
    exit 1
  fi
  if [[ "$name" != "-" ]]; then
    # Redact bearer/personal tokens; everything else is byte-for-byte what the server sent.
    if jq -e 'type == "object" and has("token")' "$WORK/resp.json" >/dev/null 2>&1; then
      jq -c '.token |= (sub("_.*"; "_") + "REDACTED")' "$WORK/resp.json" > "$FIX/$name.json"
    else
      cp "$WORK/resp.json" "$FIX/$name.json"
    fi
    printf '  %-34s %s %s → %s (%s B)\n' "$name" "$method" "$path" "$code" "$(wc -c < "$FIX/$name.json" | tr -d ' ')"
  fi
}

# upload NAME TOKEN FILE… → multipart POST /uploads (field `photos`, filename photo{n}.jpg, image/jpeg)
upload() {
  local name="$1" tok="$2"; shift 2
  local args=(-sS -o "$WORK/resp.json" -w '%{http_code}' -X POST "$API/uploads" -H "Authorization: Bearer $tok")
  local i=1
  for f in "$@"; do args+=(-F "photos=@$f;type=image/jpeg;filename=photo$i.jpg"); i=$((i + 1)); done
  local code; code="$(curl "${args[@]}")"
  LAST="$(cat "$WORK/resp.json")"
  [[ "$code" == 2* ]] || { echo "FAIL POST uploads → $code: $LAST" >&2; exit 1; }
  cp "$WORK/resp.json" "$FIX/$name.json"
  printf '  %-34s POST uploads → %s\n' "$name" "$code"
}

# poll NAME JOB_ID → polls ai/jobs/{id} until done|error; saves the first non-final poll as NAME_pending (if seen)
poll() {
  local name="$1" id="$2" status pending_saved=0
  for _ in $(seq 1 120); do
    call - GET "ai/jobs/$id"
    status="$(jq -r .status <<<"$LAST")"
    if [[ "$status" == done || "$status" == error ]]; then
      call "$name" GET "ai/jobs/$id"
      [[ "$status" == done ]] || { echo "FAIL job $id ended with error: $LAST" >&2; exit 1; }
      return
    fi
    if [[ $pending_saved == 0 ]]; then printf '%s' "$LAST" > "$FIX/${name}_pending.json"; pending_saved=1; fi
    sleep 0.5
  done
  echo "FAIL job $id did not finish" >&2; exit 1
}

login() {
  curl -sS "$API/auth/token" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"demo123\",\"device_name\":\"QA Live\"}" | jq -r .token
}

# ---------------------------------------------------------------- public / auth

echo "[auth]"
call health GET health "" ""
call auth_config GET auth/config "" ""
call auth_token POST auth/token '{"username":"demo","password":"demo123","device_name":"QA Live"}' ""
TOKEN="$(login demo)"
T_XIAOLIN="$(login xiaolin)"
T_AHAO="$(login ahao)"
call auth_me GET auth/me
TODAY="$(jq -r .today <<<"$LAST")"
PROFILE="$(jq -c .profile <<<"$LAST")"
add_days() { python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[1])+datetime.timedelta(days=int(sys.argv[2]))).isoformat())" "$1" "$2"; }
D1="$(add_days "$TODAY" -1)"; D2="$(add_days "$TODAY" -2)"; D3="$(add_days "$TODAY" -3)"
PAST="$(add_days "$TODAY" -6)"
echo "  today=$TODAY past=$PAST"
call auth_sessions GET auth/sessions
call users_before_sharing GET users

# Throwaway account: register (app token) → me → account/delete
RU="qa_$(date +%s)"
call auth_register POST auth/register "{\"username\":\"$RU\",\"password\":\"qa12345\",\"display_name\":\"QA\",\"invite_code\":\"\",\"device_name\":\"QA Live\"}" ""
T_REG="$(jq -r .token "$WORK/resp.json")"
call auth_me_no_profile GET auth/me "" "$T_REG"
call account_delete POST account/delete '{"password":"qa12345"}' "$T_REG"

# ---------------------------------------------------------------- settings / profile (SettingsBody: all five fields)

echo "[settings/profile]"
call settings_put_ahao PUT settings '{"display_name":"阿豪","avatar_color":"#b5523b","share_mode":"selected","share_detail":"full","share_with":[1]}' "$T_AHAO"
call settings_put PUT settings '{"display_name":"演示用户","avatar_color":"#2f7d5b","share_mode":"public","share_detail":"full","share_with":[]}'
call profile_put PUT profile "$PROFILE"
call profile_targets GET profile/targets
call profile_targets_date GET "profile/targets?date=$PAST"
call settings_token POST settings/token '{}'
call users GET users

# ---------------------------------------------------------------- reads

echo "[reads]"
call standards_meta GET standards/meta
call standards_dri GET standards/dri
call ai_status GET ai/status
call day_today GET "day/$TODAY"
call day_past GET "day/$PAST"
call day_empty GET "day/2025-01-01"
call day_other_full GET "day/$PAST?user=ahao"
call day_other_summary GET "day/$PAST?user=xiaolin"
call trends_7d GET "trends?start=$(add_days "$TODAY" -6)&end=$TODAY"
call trends_90d GET "trends?start=$(add_days "$TODAY" -89)&end=$TODAY"
call trends_year GET "trends?start=$(add_days "$TODAY" -364)&end=$TODAY"
call trends_other GET "trends?start=$(add_days "$TODAY" -29)&end=$TODAY&user=xiaolin"
WEEK_START="$(python3 -c "import datetime,sys;d=datetime.date.fromisoformat(sys.argv[1]);print((d-datetime.timedelta(days=d.weekday())).isoformat())" "$TODAY")"
WEEK_END="$(add_days "$WEEK_START" 6)"
MONTH_START="$(python3 -c "import datetime,sys;d=datetime.date.fromisoformat(sys.argv[1]);p=(d.replace(day=1)-datetime.timedelta(days=1));print(p.replace(day=1).isoformat())" "$TODAY")"
MONTH_END="$(python3 -c "import datetime,sys;d=datetime.date.fromisoformat(sys.argv[1]);print((d.replace(day=1)-datetime.timedelta(days=1)).isoformat())" "$TODAY")"
call period_week GET "period?start=$WEEK_START&end=$WEEK_END"
call period_month GET "period?start=$MONTH_START&end=$MONTH_END"
call period_other GET "period?start=$WEEK_START&end=$WEEK_END&user=xiaolin"
call reports_empty GET reports
call body GET body
call body_range GET "body?start=$(add_days "$TODAY" -29)&end=$TODAY"
call labs GET labs
call activity GET activity
call activity_range GET "activity?start=$(add_days "$TODAY" -29)&end=$TODAY"
call recent_items GET meals/recent-items
call health_sync_state_empty GET health/sync/state

# ---------------------------------------------------------------- meals: upload → ai/meal → preview → save → update → water

echo "[meals]"
upload uploads "$TOKEN" "$PHOTO"
PHOTO_ID="$(jq -r '.photos[0].id' <<<"$LAST")"
call ai_meal_start POST ai/meal "{\"text\":\"一碗牛肉面，加一个卤蛋，一杯豆浆\",\"date\":\"$TODAY\",\"time\":\"12:30\",\"meal_type\":\"lunch\",\"photos\":[\"$PHOTO_ID\"]}"
poll ai_meal_job "$(jq -r .job_id <<<"$LAST")"
ITEMS="$(jq -c '.result.items' "$FIX/ai_meal_job.json")"
SUMMARY="$(jq -c '.result.summary' "$FIX/ai_meal_job.json")"
call preview_meal POST preview "{\"date\":\"$TODAY\",\"meal\":{\"meal_type\":\"lunch\",\"time\":\"12:30\",\"items\":$ITEMS}}"
call meal_create POST meals "{\"date\":\"$TODAY\",\"time\":\"12:30\",\"meal_type\":\"lunch\",\"description\":\"一碗牛肉面，加一个卤蛋，一杯豆浆\",\"photos\":[\"$PHOTO_ID\"],\"ai_summary\":$SUMMARY,\"ai_model\":\"offline\",\"items\":$ITEMS}"
MEAL_ID="$(jq -r .id <<<"$LAST")"
ITEMS2="$(jq -c '.[0].amount_g = 300 | .[0].food_id = null' <<<"$ITEMS")"
call preview_meal_replace POST preview "{\"date\":\"$TODAY\",\"meal\":{\"meal_type\":\"lunch\",\"time\":\"12:30\",\"items\":$ITEMS2,\"replace_meal_id\":$MEAL_ID}}"
call meal_update PUT "meals/$MEAL_ID" "{\"date\":\"$TODAY\",\"time\":\"12:45\",\"meal_type\":\"lunch\",\"description\":\"牛肉面（大碗）\",\"photos\":[\"$PHOTO_ID\"],\"ai_summary\":\"\",\"ai_model\":\"\",\"items\":$ITEMS2}"
call water POST water "{\"ml\":250,\"date\":\"$TODAY\"}"
call water_more POST water "{\"ml\":300,\"date\":\"$TODAY\"}"

# ---------------------------------------------------------------- body / labs / exercises / activity (manual)

echo "[body]"
call body_create POST body "{\"date\":\"$TODAY\",\"time\":\"07:30\",\"weight_kg\":81.4,\"body_fat_pct\":22.5,\"waist_cm\":88,\"sbp\":124,\"dbp\":79,\"bp_treated\":false,\"note\":\"晨起\"}"
call labs_create POST labs "{\"date\":\"$D2\",\"total_chol\":190,\"hdl\":48,\"ldl\":118,\"fasting_glucose\":95,\"hba1c\":5.4,\"lipid_treated\":false,\"diabetes\":false,\"note\":\"体检\"}"
call exercise_create POST exercises "{\"date\":\"$D1\",\"time\":\"18:30\",\"activity_key\":\"jogging\",\"duration_min\":30,\"distance_km\":4.5,\"description\":\"慢跑\",\"in_device\":false,\"source\":\"manual\"}"
EX_ID="$(jq -r .id <<<"$LAST")"
call exercise_patch PATCH "exercises/$EX_ID" '{"in_device":true}'
call exercise_patch_back PATCH "exercises/$EX_ID" '{"in_device":false}'
call activity_put PUT "activity/$D1" '{"steps":8000,"active_kcal":420,"exercise_min":35,"sleep_hours":7.2}'

# ---------------------------------------------------------------- ai/activity → preview → commit

echo "[activity AI]"
call ai_activity_start POST ai/activity "{\"text\":\"今天走了 9500 步，活动消耗 480 千卡，慢跑 30 分钟 5 公里，力量训练 20 分钟，体重 81.2 公斤，血压 125/80，睡了 7 个半小时\",\"date\":\"$TODAY\",\"photos\":[]}"
poll ai_activity_job "$(jq -r .job_id <<<"$LAST")"
ADRAFT="$(jq -c .result "$FIX/ai_activity_job.json")"
ADATE="$(jq -r .date <<<"$ADRAFT")"
AACT="$(jq -c .activity <<<"$ADRAFT")"
AWORK="$(jq -c .workouts <<<"$ADRAFT")"
ABODY="$(jq -c '.body | {weight_kg, body_fat_pct, sbp, dbp} | with_entries(select(.value != null))' <<<"$ADRAFT")"
call preview_activity POST preview "{\"date\":\"$ADATE\",\"activity\":$AACT,\"body\":$ABODY,\"workouts\":$AWORK}"
call activity_commit POST activity/commit "{\"date\":\"$ADATE\",\"source\":\"ai\",\"activity\":$AACT,\"body\":$(jq -c '. + {bp_treated:false}' <<<"$ABODY"),\"workouts\":$AWORK}"

# ---------------------------------------------------------------- foods: ai/food → POST foods → reads

echo "[foods]"
call ai_food_start POST ai/food '{"name":"希腊酸奶","brand":"简爱","note":"无糖","photos":[]}'
poll ai_food_job "$(jq -r .job_id <<<"$LAST")"
FDRAFT="$(jq -c .result "$FIX/ai_food_job.json")"
FOOD_BODY="$(jq -c '{name, brand, aliases, category, serving_g, serving_desc, per100, groups100, hazards100, nova_group, ingredients, label_fields, source, source_urls: .sources, notes, visibility: "private"}' <<<"$FDRAFT")"
call food_create POST foods "$FOOD_BODY"
FOOD_ID="$(jq -r .id <<<"$LAST")"
call food_update PUT "foods/$FOOD_ID" "$(jq -c '.aliases = ["酸奶","greek yogurt"] | .visibility = "public"' <<<"$FOOD_BODY")"
call food_detail GET "foods/$FOOD_ID"
call food_seed_detail GET "foods/1"
call foods_all GET "foods?scope=all"
call foods_mine GET "foods?scope=mine"
call foods_query GET "foods?q=%E9%85%B8%E5%A5%B6&scope=all"
call food_item POST "foods/$FOOD_ID/item" '{"grams":150}'
call food_item_default POST "foods/$FOOD_ID/item" '{}'
FIRST_ITEM="$(jq -c '.[0]' <<<"$ITEMS")"
FIRST_ITEM_LIST="$(jq -c '.[0:1]' <<<"$ITEMS")"
call food_from_item POST foods/from-item "{\"item\":$FIRST_ITEM,\"name\":\"牛肉面\",\"brand\":\"\",\"aliases\":[\"拉面\"],\"serving_g\":$(jq '.amount_g' <<<"$FIRST_ITEM"),\"serving_desc\":\"一碗\",\"source_urls\":[],\"visibility\":\"private\"}"
call recent_items_after GET meals/recent-items

# ---------------------------------------------------------------- no-content / raw endpoints (deletes, password, logout, photo)

echo "[deletes & raw]"
code="$(curl -sS -o "$WORK/photo_get.bin" -w '%{http_code} %{content_type}' "$API/uploads/$PHOTO_ID" -H "Authorization: Bearer $TOKEN")"
[[ "$code" == "200 image/jpeg"* ]] && cmp -s "$WORK/photo_get.bin" "$PHOTO" || { echo "FAIL GET uploads/$PHOTO_ID → $code (bytes differ?)" >&2; exit 1; }
echo "  (photo)                            GET uploads/$PHOTO_ID → $code, bytes identical"
call - POST body "{\"date\":\"$D3\",\"time\":\"06:00\",\"weight_kg\":82,\"bp_treated\":false}"
call body_delete DELETE "body/$(jq -r .id <<<"$LAST")"
call - POST labs "{\"date\":\"$D3\",\"total_chol\":200,\"lipid_treated\":false,\"diabetes\":false}"
call labs_delete DELETE "labs/$(jq -r .id <<<"$LAST")"
call - POST exercises "{\"date\":\"$D3\",\"activity_key\":\"yoga\",\"duration_min\":20,\"in_device\":false}"
call exercise_delete DELETE "exercises/$(jq -r .id <<<"$LAST")"
call - POST meals "{\"date\":\"$D3\",\"time\":\"15:30\",\"meal_type\":\"snack\",\"description\":\"待删除\",\"photos\":[],\"ai_summary\":\"\",\"ai_model\":\"\",\"items\":$FIRST_ITEM_LIST}"
call meal_delete DELETE "meals/$(jq -r .id <<<"$LAST")"
call food_delete DELETE "foods/$(jq -r .id "$FIX/food_from_item.json")"
call password_change POST auth/password '{"old_password":"demo123","new_password":"demo1234"}'
call password_change_back POST auth/password '{"old_password":"demo1234","new_password":"demo123"}'
login demo >/dev/null   # a spare app session for DELETE auth/sessions/{id}
SPARE_ID="$(curl -sS "$API/auth/sessions" -H "Authorization: Bearer $TOKEN" | jq -r '[.[] | select(.current | not)][0].id')"
call session_delete DELETE "auth/sessions/$SPARE_ID"
T_LOGOUT="$(login demo)"
call auth_logout POST auth/logout '{}' "$T_LOGOUT"
[[ "$(curl -sS -o /dev/null -w '%{http_code}' "$API/auth/me" -H "Authorization: Bearer $T_LOGOUT")" == 401 ]] || { echo "FAIL logout did not revoke the token" >&2; exit 1; }
echo "  (logout)                           token revoked → auth/me 401"

# ---------------------------------------------------------------- period summary → reports

echo "[reports]"
call period_summary_start POST period/summary "{\"start\":\"$WEEK_START\",\"end\":\"$WEEK_END\"}"
poll period_summary_job "$(jq -r .job_id <<<"$LAST")"
# AI_PROVIDER=mock stores no summary (ai/service.ts weeklySummary() returns null for mock). Store one in exactly the shape
# weeklySummary() returns, so GET /period and GET /reports serialise a stored summary the way they do in production.
DB="${DATA_DIR:-build/qa/data}/nutrilog.db"
sqlite3 "$DB" "UPDATE reports SET ai_summary = json_object('headline','本周饮食较均衡，钠摄入偏高','summary','记录完整度良好，蔬菜与全谷物充足，但钠和添加糖多日超标。','wins',json_array('蔬菜摄入充足','每天都有记录'),'issues',json_array('钠摄入 5 天超标'),'actions',json_array('少喝汤面的汤','用无糖饮料替代含糖饮料')) WHERE user_id = 1 AND start_date = '$WEEK_START'"
call reports GET reports
call period_week_with_summary GET "period?start=$WEEK_START&end=$WEEK_END"

# ---------------------------------------------------------------- HealthKit sync

echo "[health sync]"
DEV="qa-device-0001"
SYNC1="$(cat <<JSON
{"device_id":"$DEV","device_name":"QA 的 iPhone","timezone":"Asia/Shanghai","overwrite_manual":false,
 "days":[
  {"date":"$D3","steps":10234,"active_kcal":512.4,"resting_kcal":1688.2,"distance_km":7.81,"exercise_min":42,"stand_hours":11,"sleep_hours":7.25},
  {"date":"$D2","steps":6541,"active_kcal":301.0,"distance_km":4.6,"exercise_min":18,"sleep_hours":6.5,"clear":["stand_hours"]},
  {"date":"$D1","steps":9100,"active_kcal":455.5,"exercise_min":38},
  {"date":"$TODAY","steps":3120,"active_kcal":120.3,"resting_kcal":810.0,"distance_km":2.2},
  {"date":"2099-01-01","steps":1}
 ],
 "samples":[
  {"uuid":"A1B2C3D4-0000-0000-0000-000000000001","type":"body_mass","date":"$D2","time":"07:12","start":"${D2}T07:12:30+08:00","value":81.6,"source_name":"Withings"},
  {"uuid":"A1B2C3D4-0000-0000-0000-000000000002","type":"body_fat","date":"$D2","time":"07:12","start":"${D2}T07:12:30+08:00","value":22.8,"source_name":"Withings"},
  {"uuid":"A1B2C3D4-0000-0000-0000-000000000003","type":"blood_pressure","date":"$D1","time":"21:05","start":"${D1}T21:05:00+08:00","sbp":128,"dbp":82,"bp_treated":false,"source_name":"欧姆龙"},
  {"uuid":"A1B2C3D4-0000-0000-0000-000000000004","type":"waist","date":"$D1","time":"08:00","value":87.5},
  {"uuid":"A1B2C3D4-0000-0000-0000-000000000005","type":"heart_rate","date":"$D1","time":"08:00","value":60},
  {"uuid":"A1B2C3D4-0000-0000-0000-000000000006","type":"body_mass","date":"$D1","time":"7:5","value":81.0}
 ],
 "workouts":[
  {"uuid":"W0000000-0000-0000-0000-000000000001","date":"$D1","time":"18:40","start":"${D1}T18:40:00+08:00","end":"${D1}T19:11:00+08:00","hk_activity_type":37,"activity_key":"jogging","description":"户外跑步","met":8.1,"duration_min":31,"distance_km":4.6,"avg_hr":148,"device_kcal":322.5,"in_device":true,"source_name":"Apple Watch"},
  {"uuid":"W0000000-0000-0000-0000-000000000002","date":"$D3","time":"07:00","start":"${D3}T07:00:00+08:00","end":"${D3}T07:45:00+08:00","hk_activity_type":52,"activity_key":"walk_brisk","description":"户外步行","duration_min":45,"distance_km":4.4,"avg_hr":105,"device_kcal":180,"in_device":true,"source_name":"Apple Watch"},
  {"uuid":"W0000000-0000-0000-0000-000000000003","date":"$D2","time":"20:00","hk_activity_type":20,"activity_key":"strength_training","description":"传统力量训练","duration_min":0.5,"in_device":false}
 ],
 "deleted":["DEADBEEF-0000-0000-0000-00000000FFFF"],
 "cursors":{"days":"$TODAY"}}
JSON
)"
call health_sync POST health/sync "$SYNC1"
call health_sync_resend POST health/sync "$SYNC1"
call health_sync_overwrite POST health/sync "{\"device_id\":\"$DEV\",\"device_name\":\"QA 的 iPhone\",\"timezone\":\"America/New_York\",\"overwrite_manual\":true,\"days\":[{\"date\":\"$D1\",\"steps\":9100,\"active_kcal\":455.5,\"exercise_min\":38}]}"
call health_sync_delete POST health/sync "{\"device_id\":\"$DEV\",\"device_name\":\"QA 的 iPhone\",\"timezone\":\"Asia/Shanghai\",\"overwrite_manual\":false,\"deleted\":[\"W0000000-0000-0000-0000-000000000002\",\"A1B2C3D4-0000-0000-0000-000000000002\",\"DEADBEEF-0000-0000-0000-00000000FFFF\"]}"
call health_sync_tombstoned POST health/sync "{\"device_id\":\"$DEV\",\"device_name\":\"QA 的 iPhone\",\"timezone\":\"Asia/Shanghai\",\"overwrite_manual\":false,\"samples\":$(jq -c '.samples[1:2]' <<<"$SYNC1"),\"workouts\":$(jq -c '.workouts[1:2]' <<<"$SYNC1")}"
call health_sync_state GET health/sync/state
call day_after_sync GET "day/$D1"
call activity_after_sync GET "activity?start=$D3&end=$TODAY"
call body_after_sync GET "body?start=$D3&end=$TODAY"
call health_unlink_keep POST health/sync/unlink "{\"device_id\":\"$DEV\",\"delete_data\":false}"
call health_unlink_delete POST health/sync/unlink "{\"device_id\":\"$DEV\",\"delete_data\":true}"
call health_sync_state_after_unlink GET health/sync/state

# ---------------------------------------------------------------- after writes

echo "[after writes]"
call day_today_after GET "day/$TODAY"
call auth_sessions_after GET auth/sessions
call auth_refresh POST auth/refresh '{}'
echo "collect.sh: fixtures in $FIX ($(ls "$FIX" | wc -l | tr -d ' ') files)"
