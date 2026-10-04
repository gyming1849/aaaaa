# 食迹 NutriLog for iOS

Native SwiftUI client for the NutriLog server in this repository (`../server`) (production: `http://45.63.23.52:8787`).
iPhone only, iOS 17+, Swift 6 language mode with complete strict concurrency, no third-party dependencies.

- Architecture, contracts and file ownership: [`docs/DESIGN.md`](docs/DESIGN.md)
- API and UI specs (Chinese UI strings are copied verbatim from these): [`docs/spec/00-index.md`](docs/spec/00-index.md)

## Requirements

- Xcode 27 (Swift 6.4, iOS 27 SDK). The deployment target is iOS 17.0.
- An iOS Simulator runtime (for example iPhone 18 Pro on iOS 27) for running without a device.
- A device build needs a signing team (see "Running on a device").

## Open, build and run

### In Xcode

1. Open `NutriLog.xcodeproj` and select the `NutriLog` scheme.
2. Pick a simulator and press Run.

The project uses a synchronized folder (`PBXFileSystemSynchronizedRootGroup`). Any `.swift` file you add under `NutriLog/` joins
the target automatically, so you never need to edit `project.pbxproj`.

### From the command line

The full gate runs lint, a Swift 6 typecheck, SIL data-race diagnostics, the macOS logic tests and an unsigned device build:

```bash
scripts/verify.sh                     # SKIP_XCODEBUILD=1 skips the device build
scripts/logic-tests.sh Networking     # one logic-test suite (Core, Networking, …)
```

Build, install and launch on a simulator:

```bash
xcodebuild -project NutriLog.xcodeproj -scheme NutriLog -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData-sim build

UDID=$(xcrun simctl list devices available | grep -m1 'iPhone 18 Pro (' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" build/DerivedData-sim/Build/Products/Debug-iphonesimulator/NutriLog.app
xcrun simctl launch --terminate-running-process "$UDID" com.nutrilog.ios     # add debug arguments here
xcrun simctl io "$UDID" screenshot shot.png
```

Simulator builds are signed ad hoc ("Sign to Run Locally"), so the Keychain works and the session survives relaunches.

### Running on a device

1. Set `DEVELOPMENT_TEAM` for the `NutriLog` target.
2. Enable the HealthKit capability for `com.nutrilog.ios` in the developer portal. The entitlements file already requests HealthKit and background delivery.

## Debug launch arguments (DEBUG builds only)

`App/DebugLaunchOptions.swift` reads these launch arguments for automated simulator QA. Release builds compile none of it.
In Xcode, set them under Scheme → Run → Arguments → "Arguments Passed On Launch". With `simctl`, pass them after the bundle id.

| Argument | Effect |
|---|---|
| `-NLServerURL <url>` | Use this server. The value is normalised like the 服务器 setting (`127.0.0.1:18787` → `http://127.0.0.1:18787`; a trailing `/api/v1` is stripped) and saved, so later launches keep using it. |
| `-NLToken <nla_token>` | Store this app token (`nla_…`) in the Keychain and skip the login screen. Its expiry is unknown, so the app never auto-refreshes (rotates) it. |
| `-NLTab today\|trends\|body\|more` | Select this tab once the session is ready. |
| `-NLPush <route>` | Push a route onto the selected tab once the session is ready. The route values are listed below. |
| `-NLOpenLogMeal 1` | Open the 记一餐 sheet. Pass `-NLOpenLogMeal 2026-10-01` instead to open it for that date. |
| `-NLTheme light\|dark\|system` | Theme for this launch only (the saved 外观 setting is not changed). |
| `-NLScrollTo <anchor>` | Once the screen has loaded, scroll it so this card is at the top. 今日: `score`, `energy`, `highlights`, `limits`, `le8`, `wcrf`, `hazards`, `meals`, `activity`, `details`. 趋势: `tiles`, `hei`, `energy`, `weight`, `category`, `nutrients`, `calendar`, `le8`, `wcrf`, `passrates`, `checks`, `hazards`. 身体: `weight`, `chart`, `exercises`, `activity`, `labs`, `healthsync`. 周期报告: `le8`, `tiles`, `ai`, `wcrf`, `checks`, `energy`, `hazards`, `hei`. 社区: a member's username. Apple 健康同步: `read`, `advanced`. 个人档案 and 建档: `goal`, `conditions`, `timezone`. |

`-NLPush` route values are case-insensitive; `:`, `/` or `.` separates an argument:

| Value | Screen |
|---|---|
| `foods`, `reports`, `community`, `healthSync`, `shareSettings` | 食物库, 周期报告, 社区, 苹果健康同步, 资料与分享 |
| `standards`, `standards:<tab>` | 标准库, opened on `mine` (default) or on `dri`, `hazards`, `hei`, `met`, `rules` or `sources` |
| `memberDay:<username>`, `memberTrends:<username>` | Another member's read-only day or trends |
| `profile`, `appearance`, `password`, `devices`, `server`, `deleteAccount` | 设置 pages: 个人档案, 外观, 修改密码, 登录设备, 服务器, 删除账号. `settings:<page>` also works. |

Example: sign in as a test user on a local server and open 更多 → 个人档案, in dark mode:

```bash
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"demo123","device_name":"sim QA"}' \
  http://127.0.0.1:18787/api/v1/auth/token | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
xcrun simctl launch --terminate-running-process "$UDID" com.nutrilog.ios \
  -NLServerURL http://127.0.0.1:18787 -NLToken "$TOKEN" -NLTab more -NLPush profile -NLTheme dark
```

## Server URL and App Transport Security

- **Default URL.** The default comes from the Info.plist key `NLDefaultServerURL` (`http://45.63.23.52:8787`). Users can change it on the login screen (服务器：… row) or in 更多 → 服务器. The override is stored in UserDefaults as `nl.serverURL`, and every request goes to `<base>/api/v1/…`.
- **Changing the server.** The app probes `GET /api/v1/health` before saving a new address. When a user who is signed in changes the server, the app logs them out.
- **ATS.** Production is plain HTTP on a bare IP address, which `NSExceptionDomains` cannot express. Info.plist therefore sets `NSAllowsArbitraryLoads = YES`. As a result, passwords, 365-day tokens and health data travel in cleartext. Before App Store submission (release blocker **RB-1**, DESIGN §A.8):
  1. Put the server behind a domain with TLS.
  2. Change `NLDefaultServerURL` to `https://…`.
  3. Delete the `NSAppTransportSecurity` dictionary.
- **Local server for QA.** Run it with a throwaway data directory, so that nothing touches production or `../data`:

  ```bash
  cd ../server
  export DATA_DIR=/tmp/nutrilog-qa SCHEDULER=false AI_PROVIDER=mock INVITE_CODE=test-invite PORT=18787
  npx tsx src/scripts/seedDemo.ts      # users demo / xiaolin / ahao, password demo123
  npx tsx src/index.ts
  ```

  The simulator shares the Mac's network, so the app reaches this server at `http://127.0.0.1:18787`.

## Networking notes

- One `actor APIClient` uses a cookieless `URLSession` and sends `Authorization: Bearer nla_…`. This matters because a stored `nl_session` cookie would override the token on the server.
- POST, PUT and PATCH always send `Content-Type: application/json` and a body (`{}` at minimum).
- A 401 from `auth/token`, `auth/register`, `auth/logout` or `auth/config` is a login failure, not an expired session.
- Any other 401 counts as a revoked session only when `GET auth/me` with the same token also returns 401. The app then signs out once and shows `登录已失效，请重新登录`. A request that raced a token change is replayed once with the new token.
- Photos are converted to JPEG on the device (HEIC included; long edge ≤ 2048 px, quality 0.8) and uploaded as multipart field `photos`. They are displayed through `PhotoCache` with the Bearer header.
- AI jobs are polled every 1.5 s by `JobPoller`, and `PendingJobStore` keeps job ids so an AI job can be resumed after the app relaunches.
- Logout wipes the Keychain token, the disk cache, pending jobs, the photo cache and the HealthKit state.
