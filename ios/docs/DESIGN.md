# 食迹 NutriLog iOS: architecture and implementation design

This is the lead-architect design for the **native SwiftUI iOS client** in `ios/`, plus the **additive server changes** in `server/`. It is written for parallel engineers: every shared name, signature, file path and owner is fixed here.

- Date: 2026-10-03.
- Inputs: `docs/spec/*.md` (start at `docs/spec/00-index.md`).
- Precedence:
  - For **API behaviour and UI wording**, the specs win.
  - For **new things** (iOS architecture, Swift contracts, new endpoints, file ownership), this document wins.
  - If the two conflict, raise it with the orchestrator; do not improvise.
- Spec abbreviations (as in the index):
  - `auth` = api-auth-account.md
  - `meals` = api-meals-ai-foods.md
  - `body` = api-body-health.md
  - `rep` = api-reports-trends-standards.md
  - `web1` = web-features-today-log-body.md
  - `web2` = web-features-trends-reports-misc.md

**Verified on this Mac before writing.** Xcode 27.0 (27A266a), Swift 6.4, iPhoneOS 27.0 SDK. The prototypes were built in a session scratch directory that is not part of the repo; the verified artifacts are reproduced verbatim in this document:
1. The hand-written `project.pbxproj` in §A.5 (objectVersion 77, `PBXFileSystemSynchronizedRootGroup`) builds with `xcodebuild … -sdk iphoneos CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`. The build output includes the merged Info.plist, `PrivacyInfo.xcprivacy` and `Assets.car`.
2. The Swift contract in §E.3 compiles cleanly in Swift 6 language mode. Commands run:
   - `swiftc -typecheck` with `-sdk iPhoneOS -target arm64-apple-ios17.0`.
   - `swiftc -emit-sil -wmo` with the same flags.
   - `xcodebuild`.
   - The Models and Vocab files also compile for macOS, which is the basis of the logic tests.
3. **`swiftc -typecheck` does not catch Swift 6 region-isolation ("sending") data-race errors. `-emit-sil -wmo` and `xcodebuild` do.**
   - The gate in §F therefore runs `-typecheck` and `-emit-sil` (plus `xcodebuild` as the secondary gate).
4. **Migration-v3 SQL was run in `sqlite3` 3.54.** Covered: partial-unique-index upsert, tombstone triggers, account-deletion order.
   - It exposed one bug, now fixed in §C.1. Without the `EXISTS(users)` guard in the trigger, a cascade delete of a user fails with `FOREIGN KEY constraint failed`.
5. **`fmt()` via Swift `FormatStyle` matches web `fmt` on all spec examples.** Examples: `1,568`, `39.2`, `78`, `-795`, `12,346`.

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| App type | Native SwiftUI app with no web views. iPhone only, portrait, Simplified Chinese UI with strings copied verbatim from the web. |
| Minimum OS | iOS 17.0 (`@Observable`, `chartXSelection`, HealthKit async descriptors) |
| Language mode | **Swift 6** (`SWIFT_VERSION = 6.0`), complete strict concurrency, default isolation **nonisolated**. MainActor is explicit. See §A.2. |
| State | `@MainActor @Observable final class` stores and view models. Views read `AppState` from `@Environment`. |
| Networking | One `actor APIClient` over a **cookieless** `URLSession` with Bearer `nla_` token and typed endpoint methods. |
| Charts / photos / camera | Swift Charts; `PhotosPicker`; `UIImagePickerController` wrapper. HEIC and other formats are converted to JPEG through ImageIO. |
| Health | HealthKit, read only. Uses statistics-collection, anchored-object and observer queries, background delivery, a `BGAppRefreshTask` fallback, and **one new idempotent server endpoint `POST /health/sync`**. |
| Secrets | Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |
| Dependencies | **None**. No SPM packages, CocoaPods or third-party code. |
| Project | Hand-written `NutriLog.xcodeproj` (objectVersion 77, synchronized root group), so adding a Swift file needs no project edit. |
| Bundle ID | `com.nutrilog.ios` (placeholder; set `DEVELOPMENT_TEAM` later) |
| Server URL | Default `http://45.63.23.52:8787`, editable on the login screen and in 更多 → 服务器. Every call goes to `<base>/api/v1/...`. |
| Transport | `NSAllowsArbitraryLoads = YES` **until HTTPS is deployed**. This is an App Review risk; see §A.8. |
| Server changes | Additive only. The web UI is untouched (no file under `web/` changes). There are 8 functional changes plus OpenAPI docs:<br>• migration v3<br>• `POST /health/sync`<br>• `GET /health/sync/state`<br>• `POST /health/sync/unlink`<br>• `POST /account/delete`<br>• `GET /auth/config`<br>• `current` on `/auth/sessions`<br>• `POST /auth/refresh`<br>See §C. |
| Work split | Phase 0 has WP0-A, WP0-B and WP0-C. Phase 1 has WP1 to WP9 in parallel. WP-S (server) runs in parallel from day 1. See §E. |
| Gate | `ios/scripts/verify.sh`: typecheck, SIL data-race diagnostics, macOS logic tests, lint, then `xcodebuild` (unsigned). See §F. |

---

## A. Technology decisions

### A.1 Platform
- **iOS 17.0+**, `TARGETED_DEVICE_FAMILY = 1` (iPhone), portrait only, `developmentRegion = zh-Hans`.
- Dark mode is supported. Each colour token has a light and dark value, and the user can choose 跟随系统 / 浅色 / 深色.
- Built and verified against the iOS 27 SDK. Avoid iOS 18+ only APIs unless they are behind `if #available`. For example, `HKWorkout.totalEnergyBurned` is deprecated, so use `statistics(for:)`.

### A.2 Swift 6 language mode: decision and justification
**Decision.** Use:
- `SWIFT_VERSION = 6.0` with `SWIFT_STRICT_CONCURRENCY = complete`.
- **No** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- **No** approachable-concurrency upcoming features.

Main-actor isolation is written explicitly on UI types.

Why:
- **Proven patterns.** Every concurrency-sensitive pattern this app needs compiled cleanly in Swift 6 mode on this toolchain:
  - an `actor` HTTP client with generic `Decodable & Sendable` decoding
  - `@MainActor @Observable` stores
  - HealthKit async descriptors (`HKStatisticsCollectionQueryDescriptor`, `HKAnchoredObjectQueryDescriptor`, `HKSampleQueryDescriptor`)
  - `HKObserverQuery` callbacks, `BGTaskScheduler` handlers, `PhotosPicker` and a `UIImagePickerController` coordinator
  - Keychain and ImageIO

  So the cost of Swift 6 is known and small.
- **Default MainActor isolation was tested and rejected.** With `-default-isolation MainActor`, plain `Codable` model structs get MainActor-isolated conformances. They then cannot be decoded inside the `APIClient` actor: `error: main actor-isolated conformance of 'X' to 'Decodable' cannot satisfy conformance requirement for a 'Sendable' type parameter`. Keeping isolation nonisolated by default avoids a project-wide trap.
- **Swift 5 mode was rejected.** The riskiest code is background HealthKit sync running concurrently with the UI and network actor. Compile-time race checking pays for itself there, and Swift 5 mode would only move those bugs to runtime.
- **Known gap.** `swiftc -typecheck` does not run the SIL "region isolation" diagnostics. One prototype passed `-typecheck` but failed `xcodebuild` with `passing closure as a 'sending' parameter risks causing data races`. The gate therefore also runs `swiftc -emit-sil -wmo` (§F), which reports them.

### A.3 Frameworks (Apple only)
| Need | Framework / API |
|---|---|
| UI | SwiftUI (`NavigationStack`, `TabView`, `.sheet`, `.refreshable`, `.task(id:)`, `Layout` for wrapping chips) |
| State | Observation (`@Observable`, `@Bindable`, `@Environment(AppState.self)`) |
| Networking | `URLSession` async/await (`data(for:)`, `upload` via `httpBody`). A dedicated `URLSessionConfiguration.default` with cookies fully disabled (auth §2.2). |
| Charts | Swift Charts (`LineMark`, `PointMark`, `BarMark`, `RuleMark`, `chartXSelection`). The calendar heatmap is a custom `Canvas`/grid. |
| Photos | PhotosUI `PhotosPicker` (multi-select, images); `UIImagePickerController(.camera)` wrapped in `UIViewControllerRepresentable` |
| Images | ImageIO (`CGImageSourceCreateThumbnailAtIndex` → `CGImageDestination` JPEG, orientation applied) |
| Health | HealthKit (read only), BackgroundTasks (`BGAppRefreshTask`) |
| Secrets | Security (`SecItemAdd/CopyMatching/Delete`) |
| Logging | `os.Logger` (subsystem `com.nutrilog.ios`; categories `net`, `health`, `app`). Never log tokens or health values at `.public` privacy. |

### A.4 Concurrency rules (binding for every WP)
1. **Models** (`Core/Models`) are value types: `struct … : Codable, Sendable` (or `Decodable`/`Encodable`, always `Sendable`). Never use classes. Import `Foundation` only, so they compile for macOS logic tests.
2. **UI state:** every store and view model is `@MainActor @Observable final class`.
   - Examples: `AppState`, `AppRouter`, `ToastCenter`, `PhotoUploadModel`, `HealthSyncService`, `TodayModel`, `LogMealModel`.
   - Views are `struct`s and read the app state with `@Environment(AppState.self) private var app`.
3. **I/O** lives in an `actor` (`APIClient`, `PhotoCache`, `HealthSyncEngine`, `AnchorStore`) or in a caseless `enum` of pure static functions (`ItemMath`, `LocalDay`, `SleepAggregator`, `WorkoutMapper`).
4. **No global mutable state.** `static let` constants must be `Sendable`. `nonisolated(unsafe)` is forbidden. `NumberFormatter`/`DateFormatter` must not be stored as statics; use `FormatStyle` or create them locally.
5. **Closures** that cross isolation are `@Sendable`. UI callbacks passed into views are `@MainActor` closures.
6. **Callback-based Apple APIs** (`HKObserverQuery` completion, `BGTask`) must wrap their non-Sendable parameters in `UncheckedSendable<T>` before capturing them in `Task {}`. This pattern is proven; see §E.3, `HealthBackground`. This is the **only** allowed use of `@unchecked Sendable`.
7. **Debounce, polling and cancellation** use `Task` plus `Task.sleep(for:)`. Prefer `.task(id:)` in views so SwiftUI cancels the work automatically.
8. **Large JSON** (for example `/trends` at about 3 MB) is decoded inside the `APIClient` actor, never on the main actor.
9. **No `DispatchQueue`**, no `@preconcurrency import` (unless there is a comment justifying it), and no per-file language-mode downgrades.
10. **UI updates** happen only on the main actor. View models call `await app.api.xxx()` and assign results to their `@Observable` properties afterwards.

### A.5 Project generation (hand-written, verified)

Layout:
```
ios/
  NutriLog.xcodeproj/project.pbxproj        ← verbatim template below (WP0-A)
  NutriLog/                                  ← synchronized root group: every file in here is in the target
    Info.plist                               ← excluded from membership (it is INFOPLIST_FILE)
    NutriLog.entitlements                    ← excluded from membership (it is CODE_SIGN_ENTITLEMENTS)
    Resources/Assets.xcassets, Resources/PrivacyInfo.xcprivacy
    App/ Core/ DesignSystem/ Features/
  LogicTests/  scripts/  docs/
```

Rules:
- Because of `PBXFileSystemSynchronizedRootGroup`, **adding, renaming or deleting a `.swift` file never touches `project.pbxproj`**. Only WP0-A edits that file.
- Do not create nested `.xcodeproj` folders, packages or extra targets.
- `GENERATE_INFOPLIST_FILE = YES` is merged with `INFOPLIST_FILE = NutriLog/Info.plist`. Custom keys live in the plist; standard keys come from `INFOPLIST_KEY_*` build settings.
- Bundle ID `com.nutrilog.ios`, display name `食迹`, `MARKETING_VERSION 1.0`, `CURRENT_PROJECT_VERSION 1`, `DEVELOPMENT_TEAM ""` (fill in for device runs). Code signing is automatic.
- One shared scheme, `NutriLog`, is auto-created by Xcode. If a CI needs a checked-in scheme, WP0-A adds `xcshareddata/xcschemes/NutriLog.xcscheme`; this is optional.

**`ios/NutriLog.xcodeproj/project.pbxproj`** (copy verbatim; it is verified to build):
```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXFileReference section */
		4E1A00000000000000000001 /* NutriLog.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = NutriLog.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		4E1A00000000000000000005 /* Exceptions for "NutriLog" folder in "NutriLog" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				Info.plist,
				NutriLog.entitlements,
			);
			target = 4E1A00000000000000000020 /* NutriLog */;
		};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		4E1A00000000000000000002 /* NutriLog */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				4E1A00000000000000000005 /* Exceptions for "NutriLog" folder in "NutriLog" target */,
			);
			path = NutriLog;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		4E1A00000000000000000010 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		4E1A00000000000000000003 = {
			isa = PBXGroup;
			children = (
				4E1A00000000000000000002 /* NutriLog */,
				4E1A00000000000000000004 /* Products */,
			);
			sourceTree = "<group>";
		};
		4E1A00000000000000000004 /* Products */ = {
			isa = PBXGroup;
			children = (
				4E1A00000000000000000001 /* NutriLog.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		4E1A00000000000000000020 /* NutriLog */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 4E1A00000000000000000041 /* Build configuration list for PBXNativeTarget "NutriLog" */;
			buildPhases = (
				4E1A00000000000000000011 /* Sources */,
				4E1A00000000000000000010 /* Frameworks */,
				4E1A00000000000000000012 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				4E1A00000000000000000002 /* NutriLog */,
			);
			name = NutriLog;
			packageProductDependencies = (
			);
			productName = NutriLog;
			productReference = 4E1A00000000000000000001 /* NutriLog.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		4E1A00000000000000000030 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {
					4E1A00000000000000000020 = {
						CreatedOnToolsVersion = 27.0;
					};
				};
			};
			buildConfigurationList = 4E1A00000000000000000040 /* Build configuration list for PBXProject "NutriLog" */;
			developmentRegion = "zh-Hans";
			hasScannedForEncodings = 0;
			knownRegions = (
				Base,
				"zh-Hans",
			);
			mainGroup = 4E1A00000000000000000003;
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = 4E1A00000000000000000004 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				4E1A00000000000000000020 /* NutriLog */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		4E1A00000000000000000012 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		4E1A00000000000000000011 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		4E1A00000000000000000050 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		4E1A00000000000000000051 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
			};
			name = Release;
		};
		4E1A00000000000000000052 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = NutriLog/NutriLog.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = NutriLog/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "食迹";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.healthcare-fitness";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.nutrilog.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_STRICT_CONCURRENCY = complete;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = 1;
			};
			name = Debug;
		};
		4E1A00000000000000000053 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = NutriLog/NutriLog.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = NutriLog/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "食迹";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.healthcare-fitness";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.nutrilog.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_STRICT_CONCURRENCY = complete;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = 1;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		4E1A00000000000000000040 /* Build configuration list for PBXProject "NutriLog" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				4E1A00000000000000000050 /* Debug */,
				4E1A00000000000000000051 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		4E1A00000000000000000041 /* Build configuration list for PBXNativeTarget "NutriLog" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				4E1A00000000000000000052 /* Debug */,
				4E1A00000000000000000053 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = 4E1A00000000000000000030 /* Project object */;
}
```

### A.6 Info.plist, entitlements, privacy manifest, assets

**`ios/NutriLog/Info.plist`** (custom keys only; merged with generated keys):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NLDefaultServerURL</key>
	<string>http://45.63.23.52:8787</string>
	<key>NLPrivacyPolicyURL</key>
	<string></string>
	<key>NLSupportEmail</key>
	<string></string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>NSHealthShareUsageDescription</key>
	<string>食迹会读取步数、活动能量、静息能量、步行距离、锻炼分钟、站立小时、睡眠、体重、体脂、腰围、血压、心率和体能训练记录（含骑行、游泳距离），用于计算每日能量消耗与健康评分；在你点“从‘健康’App 读取”时，还会读取性别、出生日期、身高和体重来填写个人档案。数据上传到你登录的食迹服务器；当你使用 AI 识别或 AI 周报/月报点评时，服务器会把相关数值（如体重、睡眠、血压、能量消耗）发送给第三方 AI 服务商 Anthropic 处理。</string>
	<key>NSCameraUsageDescription</key>
	<string>拍摄食物、包装、营养成分表或健康截图，上传到你登录的食迹服务器，并由第三方 AI 服务商 Anthropic 的 Claude 识别。</string>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>从相册选择食物照片、营养成分表或健康截图，上传到你登录的食迹服务器，并由第三方 AI 服务商 Anthropic 的 Claude 识别。</string>
	<key>UIBackgroundModes</key>
	<array>
		<string>fetch</string>
	</array>
	<key>BGTaskSchedulerPermittedIdentifiers</key>
	<array>
		<string>com.nutrilog.ios.healthsync.refresh</string>
	</array>
</dict>
</plist>
```

Notes:
- **`NSHealthUpdateUsageDescription` is intentionally absent.** The app requests **read-only** HealthKit access (`toShare: []`). If a later version writes dietary energy to Health, add the key then and filter echo samples (body §12.1).
- **Usage descriptions**
  - HealthKit: `NSHealthShareUsageDescription`.
  - Photo picking: `PhotosPicker` is out-of-process and needs no permission. `NSPhotoLibraryUsageDescription` is included anyway for review clarity and for any future `PHPhotoLibrary` use.
  - Camera: `NSCameraUsageDescription`.
- **`UIBackgroundModes = fetch`** is required for `BGAppRefreshTask`. HealthKit background delivery needs no background mode, only the entitlement below.
- **`NLDefaultServerURL`** is read by `ServerConfig.defaultURL`. It is a build-time default; users can still override it in the app.
- **`NLPrivacyPolicyURL`** (https page of the privacy policy) and **`NLSupportEmail`** (report / contact address) are read by `AppLinks`. They stay empty until the release values exist; the UI that uses them (更多 → 关于, the login screen's `《隐私政策》` note, 举报 mails, the consent alert's `查看隐私政策`) is hidden meanwhile, and `scripts/release-check.sh` fails (RB-3, RB-5).
- **`ITSAppUsesNonExemptEncryption = NO`**: the app only uses OS-provided crypto (URLSession TLS, Keychain), so uploads skip the export-compliance question. Revisit it if a non-OS crypto library is ever added.
- **Usage strings name the third-party AI provider** (App Store 5.1.2(i)): photos and Health-derived values reach Anthropic through the server when AI features are used. The HealthKit string also covers the onboarding prefill (sex, birth date, height), which is requested separately (§B.5 "Read set").

**`ios/NutriLog/NutriLog.entitlements`**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.healthkit</key>
	<true/>
	<key>com.apple.developer.healthkit.access</key>
	<array/>
	<key>com.apple.developer.healthkit.background-delivery</key>
	<true/>
</dict>
</plist>
```
(`com.apple.developer.healthkit.access` is empty because clinical records are not used.)

**`ios/NutriLog/Resources/PrivacyInfo.xcprivacy`**:
- Declares UserDefaults (reason `CA92.1`) and no tracking.
- Collected data: Health, Fitness, Photos, User ID, Other User Content (meal/activity text, food-library names, brands, aliases and notes) and Device ID (`DeviceInfo.installId`), all linked to the user, used for app functionality, no tracking. App Store Connect's privacy label declares the same types; the AI provider (Anthropic) is named in the privacy policy.
- Verbatim:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeHealth</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeFitness</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePhotosorVideos</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeUserID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeOtherUserContent</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeDeviceID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

**Assets.** `Resources/Assets.xcassets` contains:
- `Contents.json`
- `AccentColor.colorset`: light `#1f6f50`, dark `#3a9c73`
- `AppIcon.appiconset`: a single 1024×1024 universal slot

WP0-A renders `AppIcon-1024.png` with `scripts/make-icon.swift`, a CoreGraphics script that draws the web favicon described in web2 §3.1:
- rounded square `#1f6f50`
- leaf `#f6f5f1`
- vein stroke and dot

Every other colour is defined **in code** as a dynamic `UIColor` (§B.6), not in the asset catalog.

### A.7 Background execution
| Mechanism | Identifier / type | Purpose |
|---|---|---|
| HealthKit background delivery | entitlement `com.apple.developer.healthkit.background-delivery`; `HKObserverQuery` + `enableBackgroundDelivery` | Wake the app when new steps, energy, sleep, weight, blood pressure or workouts arrive. Steps, energy and sleep use `.hourly`; weight, BP and workouts use `.immediate`. |
| Background app refresh | `BGAppRefreshTaskRequest(identifier: "com.nutrilog.ios.healthsync.refresh")`, `earliestBeginDate = now + 4 h`, rescheduled after every sync | Fallback periodic sync |
| Foreground | `scenePhase == .active` | Refresh `me` (today rollover) and run the incremental sync |
| Finishing a sync in the background | `UIApplication.beginBackgroundTask` held by every sync loop (`BackgroundAssertion`) | Keep uploading for the ~30 s iOS allows after backgrounding / a background wake; on expiry the loop is cancelled (anchors stay uncommitted) |

Background tasks are registered in `AppDelegate.application(_:didFinishLaunchingWithOptions:)` through `HealthSyncService.registerBackgroundTasks()`. That call must happen before launch finishes. `BGProcessingTask` is not used; the initial backfill runs in the foreground with progress.

### A.8 Server URL and App Transport Security
- **Default URL.** `ServerConfig.defaultURL` = the `NLDefaultServerURL` Info.plist value (`http://45.63.23.52:8787`). The user can override it in UserDefaults `nl.serverURL`.
- **Normalising input.** `ServerConfig.normalize(_:)` trims the text, adds `http://` if no scheme is given, strips a trailing `/` and a trailing `/api` or `/api/v1`, and rejects anything without a host.
- **Probe before saving.** `GET <url>/api/v1/health` must return `{ok:true}`. Show `无法连接服务器` if it fails.
- **Where users change it.**
  - Login screen: a small "服务器：45.63.23.52:8787" row that opens a sheet.
  - Signed-in users: 更多 → 服务器. Changing it there logs the user out after confirmation (`更换服务器需要重新登录`); the confirm button is disabled while the switch runs.
  - Unreachable screen (a token is stored): 更换服务器 asks `这是同一台服务器的新地址吗？`. `是，保持登录` moves the session to the new address (`setServerURL(url, keepSession: true)`, e.g. IP → HTTPS domain, RB-1); `不是，重新登录` wipes the local session first, so the old server's token is never sent to another host.
- **ATS.** The production server is plain HTTP on a bare IP. `NSExceptionDomains` cannot express an IP literal, so `NSAllowsArbitraryLoads = YES` is required **until HTTPS is deployed**.
  - Consequences: passwords, 365-day tokens and health data travel in cleartext. App Review will ask for a justification.
  - Before App Store submission:
    1. Put the server behind a domain with TLS, for example Caddy or Nginx with `COOKIE_SECURE=true` (README).
    2. Change `NLDefaultServerURL` to `https://…`.
    3. Delete the `NSAppTransportSecurity` dict.
  - Track this as release blocker **RB-1**.

### A.9 Persistence
| Store | Contents | Owner |
|---|---|---|
| Keychain, service `com.nutrilog.ios`, account `session` | `StoredToken {token, expires_at, server}` JSON (`server` = the normalised base URL that issued it; nil for older items) | WP0-B `TokenStore` |
| UserDefaults | `nl.serverURL`, `nl.theme`, `nl.installId`, `nl.pendingJobs`, `nl.health.*` (WP9), `nl.aiConsent.<server>.<userId>` (AI consent), `nl.blocked.<server>.<userId>` (blocked members) | owners as listed |
| `Application Support/NutriLog/cache/` | `meta.json` (`Meta`, used if `version` matches), `me.json` (last `Me`; gives the time zone for background sync) | WP0-A `DiskCache` |
| `Application Support/NutriLog/health/` (excluded from backups) | archived `HKQueryAnchor`s and `sent-days.json` | WP9 `AnchorStore` |
| Memory | photo bytes (`PhotoCache` actor, about 50 MB cap) | WP0-B |

- **Logout** wipes the Keychain token, `DiskCache`, pending jobs, the photo cache, the health anchors/settings, the AI-consent answers and the blocked-members lists, because the next user is different.
- **The token is bound to its server.** The Keychain item survives an app reinstall but `nl.serverURL` does not; `TokenStore.load(for: ServerConfig.current)` discards a token issued by another server, so it is never sent to the default host. `setServerURL(keepSession: true)` re-stamps the kept token with the new address.
- **Restored backup / migrated device.** The `ThisDeviceOnly` token does not move, but UserDefaults and Application Support do. When bootstrap finds no token (Keychain answers *not found*, never on *could not read*) while `nl.health.*` or `me.json` is present, it wipes that leftover state (`healthSync.onLogout()`, caches, pending jobs) and drops `nl.installId`, so the next login starts with sync off, re-requests HealthKit authorization and backfills under a new `device_id`.
- There is **no CoreData or SwiftData**, and no offline write queue in v1. Writes require connectivity; errors are shown as toasts.

### A.10 Coding conventions
- **JSON**
  - **Property names equal JSON keys verbatim**: snake_case stays snake_case and camelCase stays camelCase.
  - Never set `keyDecodingStrategy` / `keyEncodingStrategy`; it would rewrite `totals["sodium_mg"]`.
  - Use `CodingKeys` only to exclude client-only fields (`DraftItem.localId`, `WorkoutDraft.localId`).
- **Numbers**
  - Measurements are `Double`. Only IDs and explicit counts are `Int` (rep §0.5).
  - Raw DB flags (`in_device`, `bp_treated`, `lipid_treated`, `diabetes`) are `Int` 0/1, with computed `Bool` helpers.
  - Nutrient and group vectors are `Vec = [String: Double]`; read them with `.v(key)`, which defaults to 0.
  - Never encode NaN or ∞: `ItemMath` guards every division.
- **Dates**
  - API dates stay `String` `YYYY-MM-DD` and times stay `HH:MM`. Do arithmetic with `LocalDay` (UTC Gregorian; web2 §1.4).
  - "Today" is `app.today` (= `me.today`), never the device date.
  - Server timestamps are parsed with `Timestamps.iso` (expires_at) or `Timestamps.sqlite` (`created_at`/`last_used_at`).
- **Strings**
  - All UI strings are the **verbatim Chinese** from the specs. Hard-code them inline; no `Localizable.strings`.
  - Server-provided strings (`message`, `error`, `note`) are shown as-is with `Text(verbatim:)` or `Text(stringVariable)`.
- **Errors**
  - Every thrown error reaching UI goes to `app.toasts.error(error)`, which shows `APIError.message`.
  - Screen-level load failures show a `Banner(style: .warn)` with a retry button. The web's silent failures are improved on iOS.
- **Naming**
  - One module, so all type names are global. Prefix feature types with the feature name: `TodayEnergyCard`, `LogMealModel`, `BodyWeightCard`, `TrendsScoreChart`, `ReportsAISummaryCard`, `FoodsEditorSheet`, `StandardsRulesTab`, `HealthSyncEngine`.
  - Make helpers `private` or `fileprivate` whenever possible.
- **Accessibility.** Reuse the web's aria labels as `.accessibilityLabel` (web1 §4.3, §5.3; web2 §5). Icons always come with text; status is never shown by colour alone.
- **Formatting.** Use `fmt(v, d)` and `Fmt.*` (§E.3) for **every** number shown. Never use `String(format:)`.
- **Forbidden** (enforced by `scripts/lint.sh`): `convertFromSnakeCase`, `AsyncImage(`, `URLSession.shared`, `UIApplication.shared.open` for API URLs, `print(` (use `Logger`), `NumberFormatter()` outside `Core/Util`, `nonisolated(unsafe)`, and `import UIKit` or `import SwiftUI` inside `Core/Models` or `Core/Util`.

---

## B. Source tree, responsibilities and architecture

### B.1 Directory tree with owners
"WP0-B seeds" means WP0-B creates the file as a **compilable stub with the exact signature in §E.3**. From then on the listed WP **owns** it: it may rewrite the body but **must keep every declared signature**. No file is owned by two WPs.

```
ios/
├── NutriLog.xcodeproj/project.pbxproj ............ [WP0-A] §A.5 template
├── scripts/
│   ├── verify.sh ................................. [WP0-A] full gate (§F)
│   ├── lint.sh ................................... [WP0-A] forbidden-pattern grep (§A.10)
│   ├── logic-tests.sh ............................ [WP0-A] builds and runs LogicTests/* on macOS
│   └── make-icon.swift ........................... [WP0-A] renders AppIcon-1024.png
├── LogicTests/
│   ├── Harness.swift ............................. [WP0-A] check()/expectEqual()/summary(); exit(1) on failure
│   ├── Core/main.swift, Core/sources.txt ......... [WP0-A] Format, LocalDay, Timestamps, ItemMath, model decoding fixtures
│   ├── Health/main.swift, Health/sources.txt ..... [WP9]   SleepAggregator, WorkoutMapper, DayAggregator
│   └── Trends/main.swift, Trends/sources.txt ..... [WP5]   TrendsBucketing
└── NutriLog/
    ├── Info.plist, NutriLog.entitlements ......... [WP0-A]
    ├── Resources/Assets.xcassets/…, Resources/PrivacyInfo.xcprivacy  [WP0-A]
    ├── App/                                        [WP0-B]
    │   ├── NutriLogApp.swift ...... @main; owns @State AppState; RootView; scenePhase → app.onForeground()
    │   ├── AppDelegate.swift ...... UIApplicationDelegateAdaptor; registers BG tasks + HK observers at launch
    │   ├── AppState.swift ......... session state machine (launching/unreachable/loggedOut/onboarding/ready), me, meta,
    │   │                            authConfig, dataVersion, theme, login/register/logout/bootstrap/401 handling, token refresh
    │   ├── AppRouter.swift ........ AppRouter (tabs, per-tab NavigationPath, LogMeal sheet, focus dates), Route,
    │   │                            StandardsTab, RecognizerMode, LogMealRequest
    │   ├── RootView.swift ......... switches LoadingView / unreachable+retry / LoginScreen / OnboardingScreen / MainTabView;
    │   │                            applies toastOverlay + preferredColorScheme
    │   └── MainTabView.swift ...... TabView 今日/趋势/[记一餐]/身体/更多, NavigationStacks, .sheet(LogMeal),
    │                                RouteDestinationView + View.nlRouteDestinations()
    ├── Core/
    │   ├── Networking/                             [WP0-B]
    │   │   ├── APIClient.swift ........ actor; request building, Bearer header, cookieless session, status→APIError,
    │   │   │                            401 handler, decode in actor, multipart upload, timeouts
    │   │   ├── APIClient+Account.swift  auth/config, token, register, logout, me, sessions, password, profile, targets,
    │   │   │                            settings, personal token, refresh, account delete, users (auth §3, §C)
    │   │   ├── APIClient+Body.swift ... body, labs, activity, exercises, ai/activity, preview, activity/commit,
    │   │   │                            health/sync, health/sync/state, health/sync/unlink (body §3–§4, §C)
    │   │   ├── APIClient+Log.swift .... uploads, photo bytes, ai/status, ai/meal, ai/food, jobs, meals, recent-items,
    │   │   │                            water, foods CRUD, foods/{id}/item, foods/from-item (meals §2)
    │   │   ├── APIClient+Reports.swift  day, trends, period, period/summary, reports, standards meta/dri (rep §2–§11)
    │   │   ├── APIError.swift ......... APIError + APIErrorBody + mapping rules (§B.4)
    │   │   ├── JSONCoding.swift ....... AnyEncodable, JSON encoder/decoder factories (no key strategies)
    │   │   ├── Multipart.swift ........ MultipartFile, MultipartFormData builder
    │   │   ├── ImageTranscoder.swift .. any image (HEIC/PNG/JPEG) → JPEG ≤2048 px, q 0.8, orientation applied
    │   │   ├── JobPoller.swift ........ JobPoller (1.5 s), JobPhase, PendingJob, PendingJobStore (UserDefaults)
    │   │   ├── PhotoCache.swift ....... actor; authenticated GET /uploads/{id} bytes with LRU memory cache
    │   │   └── ServerConfig.swift ..... default/override base URL, normalize(), probe()
    │   ├── Auth/                                   [WP0-B]
    │   │   ├── KeychainStore.swift .... generic password CRUD (AfterFirstUnlockThisDeviceOnly)
    │   │   ├── TokenStore.swift ....... StoredToken load/save/clear; nearExpiry(days:)
    │   │   └── DeviceInfo.swift ....... device_name ("{UIDevice.name} · 食迹 iOS", ≤60), installId (UUID, UserDefaults)
    │   ├── Models/                                 [WP0-A]  (Foundation only; mirrors spec sections)
    │   │   ├── Common.swift ........... Vec, ScoreStatus, KeyZh, OkResponse, IdResponse, JobCreated, JobStatus, Job<T>,
    │   │   │                            SourceLink, HealthPing, EmptyBody                       (meals §0.5, rep §0)
    │   │   ├── Account.swift .......... User, AIInfo, ConditionDef, Profile, Me, LoginBody, RegisterBody, TokenResponse,
    │   │   │                            SessionRow, SettingsBody, PasswordBody, ProfileSaveResponse,
    │   │   │                            PersonalTokenResponse, AuthConfig, DeleteAccountBody          (auth §3–§4, §C)
    │   │   ├── Community.swift ........ CommunityUser, RecentScore                                 (auth §4.5, rep §11)
    │   │   ├── Targets.swift .......... Targets, IntakeTarget, UpperTarget, LimitTarget, ProteinTargets, Amdr (auth §4.6, rep §4)
    │   │   ├── Scoring.swift .......... DailyScore, CompositeScore/Part, CategoryResult, ScoreItem, HeiResult/Component,
    │   │   │                            MarResult/MarNutrient, HazardResult, EnergyResult, MacroPct, Completeness, TopLists (rep §3)
    │   │   ├── Indices.swift .......... HealthIndices, Le8Result/Component, WcrfResult/Component, MepaResult/Item,
    │   │   │                            PhysicalActivitySummary                                  (rep §5)
    │   │   ├── Day.swift .............. DayResponse, Meal, MealItem, HazardEntry, ActivityDay, Exercise, BodyMetric,
    │   │   │                            LabResult                         (rep §2, meals §1.9/§1.11, body §2)
    │   │   ├── MealDraft.swift ........ DraftItem, Per100, HazardPer100, MealDraft, MealAIRequest, MealBody, PreviewMeal,
    │   │   │                            PreviewBody, PreviewRequest, DayPreview, PreviewIndices, WaterBody, WaterResponse,
    │   │   │                            RecentItem, UploadedPhoto, UploadResponse, AIStatus      (meals §1.8–§1.15, §2)
    │   │   ├── Food.swift ............. Food, FoodInput, FoodDraft, FoodScope, FoodAIRequest, FoodItemRequest,
    │   │   │                            FromItemRequest; Food.toInput(), FoodInput.blank(), FoodInput(draft:) (meals §1.12–1.14, §2.15–2.21)
    │   │   ├── Body.swift ............. BodyInput, LabInput, ActivityValues, ActivityList, ExerciseInput, ExerciseCreated,
    │   │   │                            InDeviceBody, ActivityAIRequest, BodyDraft, WorkoutDraft, ActivityDraft,
    │   │   │                            CommitBody, ActivityCommitRequest, ActivityCommitResponse  (body §2–§4)
    │   │   ├── Period.swift ........... PeriodScore, ItemStat, PeriodCheck, PeriodHazard, PeriodEnergy, PeriodSeriesPoint,
    │   │   │                            WeeklySummary, PeriodSummaryRequest, ReportListItem      (rep §6–§8)
    │   │   ├── Trends.swift ........... TrendsResponse, TrendDay                                   (rep §10)
    │   │   ├── Standards.swift ........ Meta, NutrientDef, FoodGroupDef, HazardDef, HazardDose, HazardInfoOnly, HeiDef,
    │   │   │                            ActivityDef, ActivityLevelDef, SourceDef, LifeStage, DriTables, DriIntakeRow,
    │   │   │                            DriUpperRow                                              (rep §9)
    │   │   ├── HealthSync.swift ....... SyncDay, SyncSample(Type), SyncWorkout, HealthSyncRequest/Response, Sync*Result,
    │   │   │                            KeptManual, SyncRejected, PossibleDuplicate, HealthSyncState, SyncDeviceState,
    │   │   │                            SyncKindState, SyncCounts, LegacySources, HealthUnlinkRequest/Response,
    │   │   │                            HealthSyncStatus, HealthSyncReason                       (§C.2–§C.4)
    │   │   └── Vocab.swift ............ static vocabularies and zh label maps + enums Sex/ActivityLevel/Goal/Physiology/
    │   │                                SodiumMode/Nicotine/ShareMode/ShareDetail (auth §5, meals §1.1–§1.7, rep §9, web1 §0.6)
    │   ├── Util/                                   [WP0-A]  (Foundation only)
    │   │   ├── Format.swift ........... fmt(_:_:), Fmt.signed/compact/kcal/kg/percent (web format.ts; web1 §0.3)
    │   │   ├── LocalDay.swift ......... YYYY-MM-DD arithmetic (UTC), weekStart(Mon), monthStart/End, addMonths, range,
    │   │   │                            shortDate "M/D", dateLabel "今天 · 9月30日 周三", key(for:in:), hhmm
    │   │   ├── Timestamps.swift ....... ISO-8601 (fractional) and SQLite "YYYY-MM-DD HH:MM:SS" UTC parsers
    │   │   ├── ItemMath.swift ......... rescale, toDraft, setNutrient/setGroup (unlink food_id), add/removeHazard,
    │   │   │                            totals, netKcal (meals §4, web1 §5.3)
    │   │   ├── Debouncer.swift ........ @MainActor Task-based debouncer
    │   │   ├── DiskCache.swift ........ JSON files under Application Support/NutriLog/cache
    │   │   ├── AppLog.swift ........... Logger instances (net/health/app)
    │   │   └── UncheckedSendable.swift  struct UncheckedSendable<T>: @unchecked Sendable (rule A.4.6)
    │   └── Health/                                 [WP9]   (HealthSyncService.swift seeded by WP0-B)
    │       ├── HealthSyncService.swift  @MainActor façade: status, enable/disable, syncNow, observers, BG registration
    │       ├── HealthKitManager.swift . availability, read-type set, requestAuthorization, store singleton
    │       ├── HealthTypes.swift ...... HK type ↔ server field table, units, rounding (body §12.1–§12.2)
    │       ├── HealthQueries.swift .... statistics-collection per day, stand hours, sleep samples, anchored samples,
    │       │                            BP correlations, workouts (+ per-workout statistics)
    │       ├── SleepAggregator.swift .. night attribution (D−1 18:00, D 18:00], asleep stages, union, Watch preference
    │       ├── WorkoutMapper.swift .... HKWorkoutActivityType → activity_key/description/MET, in_device rule (body §12.4)
    │       ├── DayAggregator.swift .... per-date SyncDay assembly + `clear` computation from sent-days ledger
    │       ├── AnchorStore.swift ...... actor; HKQueryAnchor archive per type; sent-days ledger; reset
    │       ├── HealthSyncEngine.swift . actor; one sync run: ranges → HK reads → chunked POST /health/sync → commit anchors
    │       ├── HealthBackground.swift . HKObserverQuery registration, enableBackgroundDelivery, BGAppRefreshTask
    │       ├── HealthSyncSettings.swift UserDefaults-backed settings + last status
    │       └── HealthProfileReader.swift sex / birth date / height / latest weight for onboarding prefill
    ├── DesignSystem/                               [WP0-C] (except Media/ = WP0-B)
    │   ├── Theme.swift ............... colour tokens (light/dark), seq palette, fonts, metrics, ThemePreference, UIColor(rgb:), Color(hex:)
    │   ├── StatusStyle.swift ......... ScoreStatus.label/symbol/fill/text/soft (web1 §0.5)
    │   ├── Components/ Card.swift (Card, CardHeader) · StatusBadge.swift · Meter.swift (Meter, MeterMark, MeterFootLink)
    │   │               ScoreRing.swift · StatTile.swift · Chip.swift (Chip, IarcChip) · Banner.swift · Seg.swift (SegOption, Seg)
    │   │               FlowLayout.swift · DateNav.swift · Avatar.swift · EmptyState.swift (EmptyState, LoadingView)
    │   │               Toast.swift (ToastCenter, toastOverlay) · SourceLinks.swift · NumberField.swift · KeyValueRow.swift
    │   │               SheetScaffold.swift (SheetScaffold, SheetAction)
    │   ├── Charts/ ChartCard.swift (ChartCard, ChartTable, ChartCell) · ChartLegend.swift (LegendItem, ChartLegend)
    │   │           ChartSeries.swift (ChartPoint, ChartSeries.segments – null-gap splitting) · ChartSelection.swift (tooltip overlay)
    │   ├── Health/ TotalPartsLine.swift · Le8Card.swift (+ MepaSheet) · WcrfCard.swift · HazardResultRow.swift
    │   │           ImpactPreviewCard.swift (web1 §3.7) · JobProgressView.swift (spinner + elapsed + staged hint)
    │   └── Media/                                  [WP0-B]
    │       ├── RemotePhoto.swift ...... authenticated thumbnail (PhotoCache), placeholder on 404
    │       ├── PhotoUploadStrip.swift . PhotoUploadModel + strip UI (PhotosPicker + camera, ≤6, transcode, upload, remove)
    │       └── CameraPicker.swift ..... UIImagePickerController(.camera) wrapper
    └── Features/
        ├── Auth/ [WP1] LoginScreen.swift (seeded) · LoginModel.swift · ServerAddressSheet.swift · OnboardingScreen.swift (seeded)
        ├── Profile/ [WP1] ProfileFormView.swift · ProfileFormModel.swift
        ├── More/ [WP1] MoreScreen.swift (seeded) · ShareSettingsScreen.swift (seeded) · ProfileSettingsScreen.swift
        │              AppearanceScreen.swift · PasswordScreen.swift · DevicesScreen.swift · ServerSettingsScreen.swift
        │              DeleteAccountScreen.swift
        ├── Today/ [WP2] TodayScreen.swift (seeded) · TodayModel.swift · TodayScoreCard.swift · TodayEnergyCard.swift
        │              TodayHighlightsCard.swift · TodayKeyLimitsCard.swift · TodayHazardsCard.swift · TodayMealsCard.swift
        │              TodayActivityCard.swift · TodayDetailTabs.swift (nutrient table, HEI tab, 评分明细 tab)
        ├── LogMeal/ [WP3] LogMealScreen.swift (seeded) · LogMealModel.swift · LogMealInputCard.swift · LogMealAnalyzingCard.swift
        │              LogMealDraftInfo.swift (summary, FollowUp, assumptions, sources) · ItemEditorView.swift
        │              ItemAdjustPanel.swift · FoodPickerSheet.swift · SaveFoodSheet.swift · QuickFoodsCard.swift
        ├── Body/ [WP4] BodyScreen.swift (seeded) · BodyModel.swift · BodyWeightCard.swift · BodyWeightChartCard.swift
        │              BodyExercisesCard.swift · BodyActivityCard.swift (form + steps chart) · BodyLabsCard.swift
        │              BodyHealthSyncRow.swift · ActivityRecognizerSheet.swift (seeded) · ActivityRecognizerModel.swift
        │              WorkoutEditorRow.swift
        ├── Trends/ [WP5] TrendsScreen.swift (seeded) · TrendsModel.swift · TrendsBucketing.swift (Foundation only)
        │              TrendsSummaryTiles.swift · TrendsScoreChart.swift · TrendsEnergyChart.swift · TrendsWeightChart.swift
        │              TrendsCategoryChart.swift · TrendsNutrientExplorer.swift · TrendsScoreCalendar.swift
        │              TrendsPassRatesCard.swift · TrendsChecksCard.swift · TrendsHazardTable.swift
        ├── Reports/ [WP6] ReportsScreen.swift (seeded) · ReportsModel.swift · ReportsAISummaryCard.swift
        │              ReportsSections.swift · ReportHistoryScreen.swift
        ├── Community/ [WP6] CommunityScreen.swift (seeded) · CommunityUserCard.swift
        ├── Foods/ [WP7] FoodsScreen.swift (seeded) · FoodsModel.swift · FoodsDetailView.swift · FoodsLookupSheet.swift
        │              FoodsEditorSheet.swift
        ├── Standards/ [WP8] StandardsScreen.swift (seeded) · StandardsModel.swift · StandardsMineTab.swift
        │              StandardsDriTab.swift · StandardsHazardsTab.swift · StandardsHeiTab.swift · StandardsMetTab.swift
        │              StandardsRulesTab.swift · StandardsRulesText.swift (verbatim rep §9.9) · StandardsSourcesTab.swift
        └── HealthSync/ [WP9] HealthSyncScreen.swift (seeded) · HealthPrefillButton.swift (seeded)
                       HealthSyncDetailsViews.swift (kept-manual, duplicates, legacy, personal token, unlink)
```

### B.2 Navigation (mirrors web `App.tsx`; web2 §2)
The web desktop sidebar (今日 趋势 报告 身体与运动 食物库 社区 标准库 设置) and mobile bottom bar (今日 趋势 + 身体 更多) map to an iOS `TabView` with five items. Each item except 记一餐 has its own `NavigationStack(path:)` with `.nlRouteDestinations()`.

| Tab | Label / SF Symbol | Root view | Path |
|---|---|---|---|
| `.today` | 今日 / `house` | `TodayScreen()` | `router.todayPath` |
| `.trends` | 趋势 / `chart.xyaxis.line` | `TrendsScreen()` | `router.trendsPath` |
| `.log` | 记一餐 / `plus.circle.fill` | none: selecting it calls `router.openLogMeal()` and **keeps the previous tab selected** | – |
| `.body` | 身体 / `scalemass` | `BodyScreen()` | `router.bodyPath` |
| `.more` | 更多 / `ellipsis.circle` | `MoreScreen()` | `router.morePath` |

`MoreScreen` is the web Settings page plus its mobile quick links, presented as a grouped `List`:
1. A profile header with the avatar, `display_name` and `@username`.
2. **快捷入口**: 周期报告 → `.reports` · 食物库 → `.foods` · 社区 → `.community` · 标准库 → `.standards(.mine)`.
3. **健康数据**: Apple 健康同步 → `.healthSync`.
4. **设置**:
   - WP1-internal pushes: 个人档案 → `ProfileSettingsScreen`, 外观 (theme plus the AI banner) → `AppearanceScreen`, 修改密码 → `PasswordScreen`, 登录设备 → `DevicesScreen`, 服务器 → `ServerSettingsScreen`.
   - 资料与分享 pushes `.shareSettings` (a cross-WP route, because Community links to it).
5. `退出登录` (destructive), then `删除账号` → `DeleteAccountScreen`.

Cross-feature links (the only allowed cross-WP couplings):
| From (WP) | Action | Call |
|---|---|---|
| Today (WP2) | `+ 记一餐` / `记录第一餐` | `app.router.openLogMeal(date: date == app.today ? nil : date)` |
| Today (WP2) | edit meal ✎ | `app.router.openLogMeal(date: meal.date, editMealId: meal.id)` |
| Today (WP2) | `评分依据` | `app.router.push(.standards(.rules))` |
| Today member (WP2) | `看趋势` | `app.router.push(.memberTrends(username:))` |
| Today (WP2) | `填写` / `AI 识别截图` | `.sheet { ActivityRecognizerSheet(date:current:mode:onDone:) }` (WP4 type) |
| Today (WP2) | hint link `身体与运动` | `app.router.showBody(date:)` |
| LogMeal (WP3) | after save | `app.router.logMeal = nil; app.noteDataChanged(); app.router.showToday(date:)` |
| Community (WP6) | tap a shared member | `.memberDay(username:)`; self → `app.router.showToday(date: nil)` |
| Community (WP6) | `我的分享设置` | `app.router.push(.shareSettings)` |
| Body (WP4) | Apple 健康同步 row | `app.router.push(.healthSync)` |
| More (WP1) | quick links | `.reports`, `.foods`, `.community`, `.standards(.mine)`, `.healthSync` |
| Onboarding (WP1) | `从“健康”App 读取` | embeds `HealthPrefillButton(onPrefill:)` (WP9 type) |

`router.push(_:)` appends to the **currently selected tab's** path; if `.log` is selected it uses `.more`. `TodayScreen` and `BodyScreen` observe `router.todayFocusDate` / `router.bodyFocusDate` with `.onChange` and then set them back to `nil`.

### B.3 App lifecycle and state flow (WP0-B)
```
App.init ─► AppState.init: ServerConfig.current, TokenStore.load(for: server) → APIClient(baseURL:token:), HealthSyncService(api:)
            (sets .current); installs the unauthorized handler at once (a background sync may hit a revoked token before bootstrap)
AppDelegate.didFinishLaunching ─► HealthSyncService.registerBackgroundTasks(); HealthSyncService.startObserversIfEnabled()
RootView.task ─► app.bootstrap(showLaunching: true):
   phase = .launching (kept .unreachable on a retry from the unreachable screen: showLaunching false)
   await api.setUnauthorizedHandler { [weak app] in await app?.handleUnauthorized() }
   no token in the client → re-read the Keychain (it may have been locked at init: launch before the first unlock)
   still no token → wipe leftover user state of a restored backup (§A.9) → phase = .loggedOut; return (LoginScreen loads auth/config)
   loadAuthConfig(timeout: 15 s) (public)                                   // §C.6
       • network error → phase = .unreachable(error.message); return   (same host: auth/me would only time out again)
   me = try await api.me(timeout: 15 s)
       • APIError.unauthorized → handleUnauthorized() (wipes the session even when a background request recorded the 401)
       • network/5xx → phase = .unreachable(error.message)  (RootView shows 重试 + 更换服务器)
   DiskCache.save(me, "me"); arm the midnight rollover; ensureMeta() (DiskCache "meta" first, network refresh if version differs)
   maybeRefreshToken(): if TokenStore expires within 30 days and authConfig.features ∋ "token_refresh" → api.refreshToken()
   phase = me.profile == nil ? .onboarding : .ready
   push an AI-consent answer the server does not have yet (background)
   if .ready → await healthSync.onSessionReady()
login/register ─► token → TokenStore.save(server: baseURL) → api.setToken → bootstrap()
didSaveProfile(p) ─► refreshMe(); if phase was .onboarding → .ready; ALWAYS await healthSync.onSessionReady() (time zone may have changed)
logout ─► build POST auth/logout with the current base URL + token → local wipe: TokenStore.clear() → api.setToken(nil)
          → DiskCache.removeAll() → PendingJobStore clear → PhotoCache.clear() → healthSync.onLogout() → router.reset()
          → AI consent / blocked lists wiped → phase = .loggedOut → send the captured request in the background (best effort, 10 s)
handleUnauthorized ─► if phase != .loggedOut: same as logout without the network call; toast error "登录已失效，请重新登录"
onForeground (scenePhase .active) ─► .ready/.onboarding: refreshMe() if the last refresh is > 5 min old or the profile-TZ day
          rolled past me.today; retry a pending token rotation (maybeRefreshToken); then healthSync.onForeground().
          .loggedOut: re-read the Keychain and bootstrap if a token appeared. .unreachable: RootUnreachableView retries itself
          (not while its 更换服务器 sheet is open, so the typed address survives).
midnight ─► while the app stays active, a one-shot refreshMe() at the next profile-TZ midnight (+2 s) rolls `today`
          (re-armed by every adopted `me`); pull-to-refresh on 今日 / 趋势 / 身体 also calls refreshMeIfDayChanged().
noteDataChanged ─► dataVersion += 1. Screens reload with `.task(id: app.dataVersion)` or `.onChange(of: app.dataVersion)`.
```

### B.4 Networking details (WP0-B)
- **URL.** `baseURL + "/api/v1/" + path`, built with `URLComponents`; query values go through `URLQueryItem` (usernames may be Chinese).
  - The photo URL returned by uploads is `/api/uploads/<id>` (unversioned). The client ignores `url` and always fetches `api/v1/uploads/<id>`.
- **Headers.** `Accept: application/json`, plus `Authorization: Bearer <token>` when a token exists.
  - **POST, PUT and PATCH always send `Content-Type: application/json` and a body**, using `EmptyBody()` (`{}`) when there is nothing to send (auth §0).
  - `DELETE` sends no body.
- **Cookies.** The configuration sets `httpCookieAcceptPolicy = .never`, `httpShouldSetCookies = false` and `httpCookieStorage = nil`. Never call `/auth/login`, and always send `device_name` on register (auth §2.2).
- **Response mapping**, in order:
  1. 2xx → decode `R`. Endpoints that return `{ok:true}` are decoded as `OkResponse` and discarded.
  2. 401 and `path` ∈ {`auth/token`, `auth/register`, `auth/logout`, `auth/config`} → `.http(401, error)`. These are login or registration failures, not session expiry.
     - This list is narrower than the web's "any `/auth/*` path" rule, so a 401 from `auth/me`, `auth/sessions` or `auth/refresh` does mean the session expired.
  3. 401 on any other path → call the unauthorized handler, then throw `.unauthorized("登录已失效，请重新登录")`.
     - Only a 401 whose body is the server's `{"error": …}` can confirm a revocation (the request's own on `auth/me`, or the `auth/me` probe's). A 401 without it (captive portal, proxy) maps to `.http(401, …)` and keeps the session.
  4. 404 with `error == "接口不存在"` → `.unsupportedByServer`. This is how new endpoints degrade on an old server.
  5. Any other non-2xx → `.http(status, body.error ?? "请求失败（\(status)）")`. A non-JSON body (for example a proxy HTML page) uses the fallback.
  6. `URLError` → `.network("网络连接失败，请检查网络或服务器地址")`, or `"请求超时"` for `.timedOut`.
  7. A decoding failure → `.decoding(...)`. The detail is logged and the user sees `数据解析失败`.
- **Timeouts.** 60 s by default. `/trends`, `/period` and `/health/sync` use 120 s; uploads use 180 s. At launch, `auth/config` and `auth/me` use 15 s (`APIClient.launchTimeout`), so a black-holed server shows 重试 / 更换服务器 after about 15 s. `auth/logout` uses 10 s and never blocks the local wipe.
- **No automatic retries.** Views offer 重试.
- **Uploads.** Multipart field `photos`, filename `photo{n}.jpg`, `Content-Type: image/jpeg`.
  - `ImageTranscoder` always converts first: long edge ≤ 2048 px, quality 0.8, which keeps files well under 12 MB.
  - At most 6 files per request and per meal (meals §2.1).
- **Photos.** `PhotoCache.data(for:api:)` sends `GET api/v1/uploads/{id}` with the Bearer header.
  - Only the owner's photos are viewable, so **member views never render photos** (rep §1).
  - `RemotePhoto` shows a neutral placeholder on 404.
- **AI jobs.** `JobPoller.wait` polls `GET ai/jobs/{id}` every 1.5 s and reports `queued`/`running` through `onPhase`.
  - It returns `result` on `done`, which can be `nil` for summary jobs.
  - It throws `.jobFailed(error ?? "AI 任务失败")` on `error`.
  - Cancelling the `Task` stops polling. The server job keeps running; on cancel, toast `已取消`.
  - The screen that starts a job saves `PendingJob{id, kind, createdAt, context}` before polling and removes it when done.
  - LogMeal resumes a pending `meal` job younger than 30 minutes (§E.2 WP3).

### B.5 HealthKit architecture (WP9; server side in §C.2)
**Read set** (`HealthKitManager.readTypes`; read-only, `toShare: []`):
- Quantity types: `stepCount`, `activeEnergyBurned`, `basalEnergyBurned`, `distanceWalkingRunning`, `distanceCycling` and `distanceSwimming` (workout distance), `appleExerciseTime`, `bodyMass`, `bodyFatPercentage`, `waistCircumference`, `bloodPressureSystolic`, `bloodPressureDiastolic`, `heartRate` (workout average only).
- Category types: `sleepAnalysis`, `appleStandHour`.
- `HKObjectType.workoutType()`.
- Not part of sync: `height` and the characteristics `biologicalSex`, `dateOfBirth` are requested only by `HealthKitManager.requestProfileAuthorization()` for the onboarding prefill (`从“健康”App 读取`).

Blood glucose, HbA1c and lipids are **not** synced; labs stay manual (body §12.1).

**Mapping and units.** These follow body §12.1–§12.2 exactly:
- steps: `.count()`, rounded to an integer
- energy: `.kilocalorie()`, rounded to 0.1
- distance: km, rounded to 0.01
- exercise: minutes, rounded to an integer
- sleep: hours, rounded to 0.01
- weight: kg, rounded to 0.1
- body fat: `.percent()` × 100, rounded to 0.1
- waist: cm, rounded to 0.1
- blood pressure: mmHg, rounded to an integer
- `avg_hr`: count/min, rounded
- `device_kcal`: kcal
- METs: from `HKMetadataKeyAverageMETs`, clamped to 1–25

**Day keys.** Use the profile time zone, never the device's (body §12.3):
- `calendar = Calendar(identifier: .gregorian)` with `timeZone = TimeZone(identifier: profile.timezone)`.
- Day key = `LocalDay.key(for: date, in: tz)`.
- The time zone comes from `app.profile?.timezone`, falling back to `HealthSyncSettings.cachedTimeZone`.
  - WP9 writes that cache in `onSessionReady()`. AppState calls `onSessionReady()` after every successful bootstrap and every profile save.
  - Because of the cache, a background launch without a UI scene still works.
- If the profile time zone differs from `TimeZone.current`, show a warning in the sync screen (`当前设备时区与档案时区不同，按档案时区 {tz} 统计每天的数据`).

**One sync run** (`HealthSyncEngine.run(context:)`, single-flight; concurrent requests coalesce):
1. **Choose the range.**
   - First run, or after 重新同步全部: `[today − backfillDays + 1 … today]`. `backfillDays` defaults to **90**, with options 30 / 90 / 365 labelled 30 天 / 90 天 / 一年.
   - Foreground or manual run: `[max(lastMaxDate − 6, today − backfillDays + 1) … today]`, where `lastMaxDate` comes from `GET /health/sync/state` for this `device_id` (kind `days`). That covers 7 days of late Watch data.
   - Observer or background-refresh run: `[today − 1 … today]`.
2. **Days** (`HealthQueries` + `DayAggregator`):
   - `HKStatisticsCollectionQueryDescriptor(.cumulativeSum, anchorDate: startOfDay(start), intervalComponents: day 1)` for steps, active, basal, distance and exercise. A day with no samples is `nil`, **never 0**.
     - HealthKit steps the intervals with the device calendar. When the offset between the profile and device zones changes inside the range (DST in only one of them), hourly buckets anchored at a profile midnight are summed per profile-zone day instead (`HealthSyncText.zonesStayAligned`).
   - Stand hours: count `appleStandHour` samples whose value is `.stood`, grouped by the day key of `startDate`.
   - Sleep: `SleepAggregator.hoursByDay`. Asleep values are {1,3,4,5}. The window for date D is `(D−1 18:00, D 18:00]` in the profile time zone. Intervals are clipped and unioned across sources. If any asleep sample in the window comes from an Apple Watch (`sourceRevision.productType` starts with `Watch`), use only Watch samples. Otherwise fall back to `inBed` hours, marked as approximate in the UI. No data gives `nil`.
   - `clear`: for each field the sent-days ledger (`AnchorStore`, last 14 days) recorded as sent non-nil for D but which is now `nil` — **only for fields readable in this run**, i.e. with a value on at least one date of the run. HealthKit reports a read denial (permission revoked in Settings, or Health data still downloading on a restored device) as "no data", so a field empty on every date is never treated as deleted. Its ledger entry is kept (`record` = old − cleared ∪ valued), so a real deletion is cleared by a later run in which the field has data on some date of the 14-day window.
3. **Samples** use `HKAnchoredObjectQueryDescriptor` per type, with the stored anchor and the predicate `startDate ≥ today − backfillDays`:
   - Types: `bodyMass`, `bodyFatPercentage`, `waistCircumference`, and the blood-pressure correlation (`HKCorrelationType(.bloodPressure)`; sbp and dbp come from `objects(for:)`).
   - Each sample becomes a `SyncSample` with `uuid` = sample or correlation UUID, a profile-time-zone `date`/`time`, `start` = ISO-8601 with offset, and `source_name` = `sourceRevision.source.name` (truncated to 60).
   - BP readings use `bp_treated = HealthSyncSettings.bpTreated`.
   - Skip any sample whose `sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier` (echo filter).
4. **Workouts** use an anchored query on `workoutType()` with the same predicate. Each one goes through `WorkoutMapper` (body §12.4):
   - `duration_min = duration/60`, rounded to 0.1. Skip workouts under 1 minute; clamp to 1440.
   - `distance_km` comes from `statistics(for: distanceWalkingRunning | distanceCycling | distanceSwimming).sumQuantity()`.
   - `avg_hr` comes from `statistics(for: heartRate).averageQuantity()`.
   - `device_kcal` comes from `statistics(for: activeEnergyBurned).sumQuantity()`.
   - `met`: use `HKMetadataKeyAverageMETs` if present; otherwise omit it and the server uses the table MET.
   - `activity_key` and `description` follow the mapping table in body §12.4. The description is the Chinese HK type name, for example `户外跑步` or `泳池游泳`.
   - **`in_device = (device_kcal ?? 0) > 0 && (dayActiveKcal[date] ?? 0) > 0`** (body §8.1). `dayActiveKcal` comes from step 2.
   - The anchored workout query runs **before** step 2: the dates of new workouts outside the range are added to the step-2 day-totals read and uploaded with it, so a late workout's `in_device` and that day's `active_kcal` reach the server together. Only a workout dated tomorrow (time zone edge) still queries its day's active energy separately. `coveredDates` reports the widened set.
5. **Deletions.** Collect the `deletedObjects` UUIDs from every anchored query into `deleted`.
6. **Send** `POST /health/sync` in chunks: days 90 per request; samples plus workouts 800 per request; `deleted` 2000 per request.
   - Order: days, then samples, then workouts, then deletions.
   - After each 200 response, record the sent days in the ledger, and **commit the anchor for each type whose new objects have all been accepted**. Never commit an anchor before the server responds 200. Every write is idempotent, so retries are safe.
7. **Record the outcome** in `HealthSyncStatus`:
   - `lastSyncAt`
   - `lastSummary`, e.g. `同步了 30 天活动、12 条身体数据、3 次运动`
   - `keptManualDates`
   - possible duplicates, legacy-source counts and `timezone_mismatch`
   - Then call `app.noteDataChanged()` if anything changed, and reschedule the background-refresh task.

**Errors.**
- `HKError.errorDatabaseInaccessible` (device locked): defer silently, with the status text `设备锁定时无法读取健康数据，解锁后会自动同步`.
- Network error: keep the anchors and retry on the next trigger.
- `.unsupportedByServer`: set `status.serverSupportsSync = false`, stop automatic sync and show `服务器需要升级后才能同步“健康”App 数据` (requires WP-S to be deployed).
- 400 for the whole request: show the server message.

**Triggers.**
- Launch with sync enabled.
- Foreground, if the last automatic sync was more than 10 minutes ago.
- Observer callbacks, throttled to at most one per 10 minutes. Weight, BP and workout callbacks bypass the throttle.
- Background refresh.
- The 立即同步 button.
- Changes to sync settings.

**Background** (`HealthBackground`):
- `startObserversIfEnabled()` runs at launch. It creates one `HKObserverQuery` per type in {steps, activeEnergy, sleep, bodyMass, bodyFat, bloodPressureSystolic, workout} and calls `enableBackgroundDelivery` (hourly for steps, energy and sleep; immediate for the rest).
- In each callback, the completion handler is wrapped in `UncheckedSendable` (`ObserverAck`, fires once) and called when the observer's sync finishes **or after 20 s, whichever comes first**. HealthKit stops background delivery after three unacknowledged deliveries; acknowledging early loses nothing, because anchors are committed only after the server accepted the data.
- An urgent callback (weight, body fat, BP, workouts) that arrives while a standard or overwrite run (e.g. a long backfill) is in progress only queues the recent days, which the running loop picks up before it ends.
- Every sync loop holds a `UIApplication` background task (`BackgroundAssertion`). When its time runs out the loop is cancelled (`cancelBackgroundWork`): the engine throws `CancellationError` at the next check or request, anchors stay uncommitted, and `drain` starts a fresh loop on the next trigger.
- `BGAppRefreshTask` runs `syncNow(.backgroundRefresh)`, cancels on expiration and reschedules.
- Background runs read the token from the Keychain (accessible after first unlock) and the time zone from `HealthSyncSettings`.

**Conflict rules.** The server enforces these; the client chooses the policy.
| Case | Result |
|---|---|
| A day field HealthKit wrote, which the user has not changed | Updated by every sync |
| A day field the user edited or cleared on web or iOS (`PUT /activity`), so `source = manual` and the value differs from the last HealthKit value | **Kept.** Reported in `kept_manual`; the UI offers `用“健康”App 数据覆盖这些日期`, which re-syncs those dates with `overwrite_manual: true`. |
| A synced workout whose `in_device` the user toggled (`PATCH /exercises/{id}`) | **Kept.** A re-sent workout (retry, 重新同步全部) updates every other field; `in_device` is only set on insert. |
| Rows from 快捷指令, export, or AI screenshots (`apple_shortcut` / `apple_export` / `ai_screenshot`) | Overwritten by HealthKit |
| Weight, fat, waist and BP samples | Separate rows (`source = healthkit`), upserted by UUID. Manual rows are untouched; scoring uses the last reading by time. |
| A synced row deleted on the web or in the app | A tombstone is recorded and the row is never re-created |
| A HealthKit workout matching an existing manual or AI exercise | Inserted. The server returns `possible_duplicates`, and the sync screen lists them with `删除手动记录` (`DELETE /exercises/{id}`). |
| The user still runs the Shortcut automation | If `legacy_sources.apple_shortcut_days > 0`, show the banner `检测到 iPhone 快捷指令同步的数据。开启 App 同步后，请关闭快捷指令自动化，避免重复。` |

**`HealthSyncScreen`** (WP9; replaces the web "连接苹果健康" card, web1 §7.2 Row 4). Sections:
1. Availability (`HKHealthStore.isHealthDataAvailable()`).
2. Toggle `同步“健康”App 数据`. Turning it on requests authorization, starts the observers and runs the initial sync with a progress spinner. Pull-to-refresh refreshes the server state and starts a sync without waiting for it (none while one runs). The footer says where the data goes, including the AI provider (`HealthSyncText.uploadDisclosure`).
3. The list of data read, and the note `可在“设置 → 健康 → 数据访问与设备 → 食迹”中修改权限`. iOS hides which read permissions were denied.
4. `上次同步 {time}` with the summary and a `立即同步` button.
5. Backfill Seg: `30 天` / `90 天` / `一年`.
6. Toggle `正在服用降压药`, applied to synced BP.
7. Kept-manual list with its override button.
8. Possible duplicates.
9. Legacy-Shortcut banner and time-zone warning.
10. 高级:
    - `重新同步全部`: resets the anchors and the ledger.
    - `个人 Token（快捷指令）`: `POST /settings/token`, using the web strings in auth §3.13.
    - `断开并删除已同步的数据`: `POST /health/sync/unlink {delete_data:true}` after confirmation, then disable sync.

### B.6 Design system (WP0-C; tokens from web1 §0.4 / web2 §3.2)
- **`Theme` colours.** Each is a dynamic `Color` built from `UIColor { traits in … }`:
  - surfaces and ink: `page, surface, surface2, surface3, ink, ink1, ink2, ink3, hair, axis, border`
  - accent: `accent, accentHover, accentInk, accentSoft, accentText`
  - status: `good, warning, serious, critical`, each with a `…Text` and `…Soft` variant
  - chart series: `s1…s5`
  - heatmap: `seq(_ step: Int)` (7 steps; the dark list is reversed)
  - Hex values are copied exactly from web2 §3.2.
- **Type and metrics.**
  - `Theme.Font` tokens follow **Dynamic Type**: each is the nearest text style to the web size (at the default size `h1` title2 22 semibold, `h2` headline 17, `h3`/`body` subheadline 15, `small` footnote 13, `statValue` title 28; component tokens map to subheadline / footnote / caption / caption2). Only `ringBig` 48 bold and `ringSmall` 32 stay fixed (inside a fixed ring). `NLButtonStyle` and `NumberField` use minimum heights so labels grow instead of clipping; the root caps the size at `accessibility2`. Numbers use `.monospacedDigit()`. Inline `.font(.system(size:))` calls in feature views are a follow-up to move onto the tokens.
  - Touch targets: icon-only `.sm` buttons take touches in 40 × 40 around their 30 pt look; the photo remove button in 44 × 44 around its 22 pt circle.
  - Metrics: card radius 14, padding 16, small radius 10, chip radius 99.
- **Components** (signatures in §E.3) reproduce the web's `Meter`, `ScoreRing`, `StatusBadge`, `Chip`/`IarcChip`, `Banner`, `Seg`, `DateNav`, `Avatar`, `EmptyState`/`LoadingView`, Toast (info 2.6 s, error 5 s, top centre) and `SourceLinks`, including:
  - the maths (meter scale ×1.08, ring colour thresholds 70/55/40)
  - the text (`达标/偏离/不达标/提示`, `IARC {g} 类`, `非致癌`, `依据：`)
- **Charts** (web2 §4):
  - `ChartCard` has a title, a hint, a `表格/图表` toggle and a 260 pt chart area; the table mode has a 300 pt max height and a `日期` first column.
  - `ChartLegend` uses 14×3 swatches.
  - `ChartSeries.segments` splits series at `nil` so lines show gaps (`connectNulls: false`).
  - The selection overlay uses `chartXSelection` with a `RuleMark` and a tooltip card.
- **Shared health cards**, used by Today, Trends, Reports, LogMeal and ActivityRecognizer:
  - `TotalPartsLine` (web1 §3.4), `Le8Card` + `MepaSheet` (web1 §3.5), `WcrfCard` (web1 §3.6)
  - `HazardResultRow` (web1 §4.3 D), `ImpactPreviewCard` (web1 §3.7)
  - `JobProgressView`: spinner, `排队中…` or the title, `{n}s`, and the staged hint computed from elapsed seconds.

---

## C. Server changes (WP-S): additive only, web unaffected

### C.0 Principles and file list
- **Nothing under `aaaaa/web/` changes.**
- **No existing endpoint changes its required inputs, status codes or existing response keys.** Allowed changes are:
  - new routes
  - new nullable columns, which only add keys to `SELECT *` rows the web ignores
  - one new optional response field (`current` on `GET /auth/sessions`, which the web never calls)
  - new exported helpers
  - one new mount line
- Scoring reads tables regardless of `source`, so synced data appears in `/day`, `/trends`, `/period`, LE8, WCRF and energy **with no scoring change**:
  - `activity_days` feeds `loadDays` → `computeEnergy` / composite activity / LE8 sleep and PA.
  - `exercises` feeds energy, PA minutes and strength days.
  - `body_metrics` feeds `getWeights` (BMI, targets, EMA), the BP average and WCRF waist.
  - Cache invalidation reuses `invalidateFrom()`.
- **Cosmetic effects on the web, all accepted with no layout change:**
  - Rows with `source='healthkit'` show the label `Apple 健康` in the Body list (the web's fallback says `苹果健康`; iOS follows Apple's naming, F13).
  - The Body activity hint shows `来源：“健康”App 导出` (web fallback: `苹果健康导出`).
- **Database:** one new migration (v3). It is applied automatically on the next server start by the existing `migrate()` loop. **Back up `data/nutrilog.db` before deploying.**

| File | Change | Kind |
|---|---|---|
| `server/src/db/index.ts` | Append migration **v3** string to `MIGRATIONS` (§C.1) | additive |
| `server/src/routes/app.ts` | **New** `appRouter`: `GET /auth/config`, `POST /auth/refresh`, `POST /account/delete`, `POST /health/sync`, `GET /health/sync/state`, `POST /health/sync/unlink` | new file |
| `server/src/services/healthsync.ts` | **New** pure service functions `applyHealthSync`, `healthSyncState`, `unlinkHealthDevice` | new file |
| `server/src/services/accountDeletion.ts` | **New** `deleteUserCompletely(uid)` | new file |
| `server/src/index.ts` | `import { appRouter } from "./routes/app.ts";` and `app.use(prefix, appRouter);` **immediately after** `app.use(prefix, accountRouter);`. It must come before `bodyRouter` and `logRouter`, so the public `/auth/config` is not caught by `logRouter`'s router-level `requireAuth`. | 2 lines |
| `server/src/auth.ts` | **Add exports** `presentedToken(req): {token: string; via: "cookie"\|"bearer"} \| undefined` (same precedence as `userFromSession`) and `currentTokenHash(req): string \| undefined`. Existing functions are unchanged. | additive |
| `server/src/routes/account.ts` | `GET /auth/sessions` adds a boolean `current` per row (§C.7) | additive field |
| `server/src/openapi.ts` | New OPS entries and schemas (§C.9) | docs |
| `server/test/helpers/testApp.ts`, `server/test/healthsync.test.ts`, `server/test/appAccount.test.ts` | **New** tests (§C.10) | new files |

### C.1 Migration v3 (append as the 3rd element of `MIGRATIONS`)
Verified in sqlite3 3.54. The `EXISTS(users)` guard keeps `DELETE FROM users` cascades working; without it the cascade fails with `FOREIGN KEY constraint failed`.
```sql
-- v3：苹果健康（HealthKit）直连同步：外部 ID、墓碑、按天快照、同步状态
ALTER TABLE body_metrics ADD COLUMN external_id TEXT;      -- HK sample UUID（血压为 correlation UUID）
ALTER TABLE body_metrics ADD COLUMN source_name TEXT;      -- HKSource 名称，如 “Withings”“XX 的 Apple Watch”
CREATE UNIQUE INDEX idx_body_ext ON body_metrics(user_id, external_id) WHERE external_id IS NOT NULL;

ALTER TABLE exercises ADD COLUMN external_id TEXT;         -- HKWorkout UUID
ALTER TABLE exercises ADD COLUMN source_name TEXT;
ALTER TABLE exercises ADD COLUMN started_at TEXT;          -- ISO-8601 带时区偏移
ALTER TABLE exercises ADD COLUMN ended_at TEXT;
ALTER TABLE exercises ADD COLUMN hk_activity_type INTEGER; -- HKWorkoutActivityType 原始值
CREATE UNIQUE INDEX idx_ex_ext ON exercises(user_id, external_id) WHERE external_id IS NOT NULL;

-- HealthKit 最近一次写入每天各字段的值：用于判断用户是否手动改过（手动修改优先）
CREATE TABLE health_day_snapshots (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  steps REAL, active_kcal REAL, resting_kcal REAL, distance_km REAL, exercise_min REAL, sleep_hours REAL, stand_hours REAL,
  synced_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, date)
);

-- 网页 / App 删除的同步记录不会被再次同步回来
CREATE TABLE health_tombstones (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  external_id TEXT NOT NULL,
  kind TEXT NOT NULL,                       -- body | exercise
  deleted_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, external_id)
);
CREATE TRIGGER trg_body_tomb AFTER DELETE ON body_metrics
  WHEN old.external_id IS NOT NULL AND EXISTS (SELECT 1 FROM users WHERE id = old.user_id)
BEGIN INSERT OR IGNORE INTO health_tombstones (user_id, external_id, kind) VALUES (old.user_id, old.external_id, 'body'); END;
CREATE TRIGGER trg_ex_tomb AFTER DELETE ON exercises
  WHEN old.external_id IS NOT NULL AND EXISTS (SELECT 1 FROM users WHERE id = old.user_id)
BEGIN INSERT OR IGNORE INTO health_tombstones (user_id, external_id, kind) VALUES (old.user_id, old.external_id, 'exercise'); END;

CREATE TABLE health_sync_state (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,                  -- App 安装 ID（UUID）
  device_name TEXT,
  kind TEXT NOT NULL,                       -- days | samples | workouts
  last_synced_at TEXT NOT NULL,             -- datetime('now')
  min_date TEXT, max_date TEXT,
  cursor TEXT,
  PRIMARY KEY (user_id, device_id, kind)
);
```
Every new column is nullable, so existing INSERTs keep working, and existing rows get `NULL`.

### C.2 `POST /api/v1/health/sync`: batched, idempotent HealthKit upload
- **Auth:** `requireAuth`. The `nla_` app token works; the personal `nl_` token is rejected, as for every non-ingest route.
- **Profile required:** `400 请先完善个人档案` (weights and workout kcal need it).
- **Body:** JSON, up to the existing 2 MB limit.

**Request**
```jsonc
{
  "device_id": "4F0C2E7A-…",        // required, trimmed, ≤64  → else 400 "device_id 不能为空"
  "device_name": "小林的 iPhone",    // optional, ≤60
  "timezone": "Asia/Shanghai",       // optional; tz the client used for day keys
  "overwrite_manual": false,         // optional bool (real JSON boolean; anything else = false)
  "days": [ { "date": "2026-10-02", "steps": 8532, "active_kcal": 412.3, "resting_kcal": 1620.4, "distance_km": 6.12,
              "exercise_min": 35, "stand_hours": 11, "sleep_hours": 7.25, "clear": ["sleep_hours"] } ],
  "samples": [
    { "uuid": "8A1E…", "type": "body_mass", "date": "2026-10-02", "time": "22:31", "start": "2026-10-02T22:31:05+08:00", "value": 68.2, "source_name": "Withings" },
    { "uuid": "…", "type": "body_fat", "date": "…", "time": "…", "value": 21.5 },
    { "uuid": "…", "type": "waist", "date": "…", "time": "…", "value": 82.0 },
    { "uuid": "…", "type": "blood_pressure", "date": "…", "time": "…", "sbp": 118, "dbp": 76, "bp_treated": false }
  ],
  "workouts": [ { "uuid": "…", "date": "2026-10-02", "time": "18:05", "start": "2026-10-02T18:05:00+08:00", "end": "2026-10-02T18:50:12+08:00",
                  "hk_activity_type": 37, "activity_key": "run_10kmh", "description": "户外跑步", "met": 9.3,
                  "duration_min": 45.2, "distance_km": 7.4, "avg_hr": 152, "device_kcal": 480, "in_device": true, "source_name": "Apple Watch" } ],
  "deleted": ["uuid-1", "uuid-2"],
  "cursors": { "samples": "opaque", "workouts": "opaque" }   // optional strings ≤4096, stored verbatim
}
```
- **Every section is optional.**
- **Size limits** (`400 单次同步数据过多，请分批上传` if exceeded): `days` ≤ 400, `samples` ≤ 2000, `workouts` ≤ 500, `deleted` ≤ 2000.
- **Wrong section type:** a section that is present but not an array → `400 请求格式不正确`.

**Validation per item.** An invalid item goes to that section's `rejected` with the server's Chinese message and **never fails the batch**. Valid items are all written in **one `tx()`**.
- **Common checks**
  - `date` must pass `isDate` and be ≤ `addDays(todayIn(profile.tz), 1)`; otherwise `日期格式不正确` / `日期不能晚于今天`.
  - `time` must match `TIME_RE`, else `时间格式不正确`.
  - `uuid` must be a non-empty string ≤ 64, else `uuid 不能为空`.
- **days:** each provided field uses `num(v, {min, max, optional: true, name: <key>})` with the same ranges as `PUT /activity` (`ACT_FIELDS` in body.ts):
  - `steps` 0–200000, `active_kcal` 0–10000, `resting_kcal` 0–5000, `distance_km` 0–500, `exercise_min` 0–1440, `sleep_hours` 0–24, `stand_hours` 0–24
  - `clear` is filtered to those 7 keys.
- **samples**
  - `body_mass.value` 20–350 (`体重`), `body_fat.value` 2–70 (`体脂率`), `waist.value` 30–250 (`腰围`)
  - `blood_pressure`: `sbp` 60–260 **and** `dbp` 30–160, both required (`收缩压` / `舒张压`)
  - Unknown `type` → `类型不正确`.
- **workouts**
  - `duration_min` 1–1440 (`时长`), `met` 1–25 if present (`MET`), `distance_km` 0–1000 (0 → null), `avg_hr` 30–230, `device_kcal` 0–10000
  - `activity_key`: an unknown key falls back to `other_moderate`
  - `description` ≤ 80 (default: the activity's `zh`)
  - `start`/`end` ≤ 40 characters, `source_name` ≤ 60, `hk_activity_type` an integer or null

**Semantics.** Let `tz = profile.timezone`.
- **days.** For each valid day, let `row` be the `activity_days` row and `snap` the `health_day_snapshots` row. For each field `f` that has a provided non-null value `v`, or is in `clear` (where `v = NULL`):
  - **No `row`:** write.
  - **`row.source != 'manual'`** (`healthkit`, `apple_shortcut`, `apple_export`, `ai_screenshot`, …): write.
  - **`row.source == 'manual'`:**
    - With `overwrite_manual`: write.
    - Otherwise, if `snap?.f` is non-null: write only if `approxEq(row.f, snap.f)` (|Δ| < 1e-6), meaning the user has not changed what HealthKit last wrote. Otherwise keep it.
    - Otherwise (`snap?.f` is null): write only if `row.f IS NULL` (filling a gap). Otherwise keep the user's own value.
    - Each kept field is added to `kept_manual[{date, fields}]`.
  - **Resulting row:**
    - Insert or update `activity_days` with the merged values and `updated_at = datetime('now')`.
    - `source = (row?.source == 'manual') ? 'manual' : 'healthkit'`.
    - If every merged value equals the existing one, do **not** touch the row (counted as `unchanged`); otherwise count it as `upserted`.
  - **Snapshot:** always upsert it. Set `snap.f = v` for each provided field, `NULL` for each cleared field, and `synced_at = datetime('now')`. Fields that are neither provided nor cleared keep their snapshot value.
- **samples.**
  - **Tombstoned** `(user_id, uuid)`: count as `skipped_tombstoned`.
  - **Otherwise, look up the existing row** by `(user_id, external_id)`.
    - Not found: `INSERT` with `source='healthkit'`, `note=NULL`, `external_id=uuid`, `source_name`, and `bp_treated = bp_treated ? 1 : 0`. Map the type to its column: `body_mass` → `weight_kg`, `body_fat` → `body_fat_pct`, `waist` → `waist_cm`, `blood_pressure` → `sbp`/`dbp`. Count as `inserted`.
    - Found and some value, date or time differs: update using `INSERT … ON CONFLICT(user_id, external_id) WHERE external_id IS NOT NULL DO UPDATE SET …`. Count as `updated`.
    - Found and identical: count as `unchanged`.
  - One row per sample; weight and fat stay in separate rows, and existing readers handle that.
- **workouts.**
  - **Tombstoned:** skip.
  - **Otherwise compute:** `act = ACTIVITY_MAP[key] ?? ACTIVITY_MAP.other_moderate`, `met = met ?? act.met`, `weight = weightOn(getWeights(uid, date), date, profile.weight_kg)` and `kcal = Math.round(netKcal(met, weight, duration_min))`. This is exactly the `POST /exercises` formula.
  - **Upsert** by `(user_id, external_id)` with `time` = the workout start `HH:MM`, `in_device = in_device ? 1 : 0`, `avg_hr`, `device_kcal`, `source='healthkit'`, `source_name`, `started_at`, `ended_at` and `hk_activity_type`. Count it as inserted, updated or unchanged as for samples.
  - **Possible duplicates.** For each **inserted** workout, find existing rows with the same `user_id` and `date`, `source != 'healthkit'`, the same activity family (the `activity_key` prefix before the first `_`, e.g. `run`, `swim`, `walk`, `cycle`; otherwise exact key equality), and `|duration − d| ≤ 0.2·d`. Report `{uuid, exercise_id, description}`. **Never auto-delete.**
- **deleted.**
  - First `SELECT id, date FROM body_metrics|exercises WHERE user_id=? AND external_id IN (…)`, to record the dates, then `DELETE`.
  - The triggers create tombstones.
  - Count the deletions per table; `not_found` = uuids that matched nothing.
- **Invalidation.** Track `minChangedDate` over every inserted, updated or deleted row and every upserted day; unchanged items do not count. After the transaction, if it is set, call `invalidateFrom(uid, minChangedDate)` once. This removes cached daily scores ≥ that date and unsummarised report rows, the same as existing body writes.
- **State.**
  - For each section present (`days`, `samples`, `workouts`), upsert `health_sync_state(user_id, device_id, kind)` with `device_name`, `last_synced_at = datetime('now')`, and the min/max `date` of that section's valid items. The existing min/max is kept if the section has no valid items.
  - Set `cursor = cursors[kind] ?? existing`.

**Response 200**
```jsonc
{
  "ok": true,
  "timezone": "Asia/Shanghai", "server_today": "2026-10-03",
  "timezone_mismatch": false,                    // body.timezone present && != profile.timezone
  "days":     { "upserted": 30, "unchanged": 2, "kept_manual": [ { "date": "2026-10-01", "fields": ["sleep_hours"] } ], "rejected": [ { "date": "2026-13-01", "error": "日期格式不正确" } ] },
  "samples":  { "inserted": 12, "updated": 0, "unchanged": 3, "skipped_tombstoned": 1, "rejected": [ { "uuid": "…", "error": "体重不能大于 350" } ] },
  "workouts": { "inserted": 3, "updated": 1, "unchanged": 0, "skipped_tombstoned": 0, "rejected": [], "possible_duplicates": [ { "uuid": "…", "exercise_id": 812, "description": "游泳" } ] },
  "deleted":  { "body": 1, "exercises": 0, "not_found": 2 },
  "invalidated_from": "2026-09-03"               // or null
}
```
Sections absent from the request are absent from the response; `invalidated_from` is always present. Each `rejected` item has `error` and either `date` (days) or `uuid` (samples, workouts). Status codes: 400 for whole-request problems only; 401; 413 is not reachable, because a body over 2 MB fails as 500 under the existing behaviour, so the client chunks.

**Implementation shape** (`services/healthsync.ts`):
```ts
export interface SyncResult { /* exactly the response shape above */ }
export function applyHealthSync(uid: number, body: unknown): SyncResult            // throws HttpError(400) only for whole-request errors
export function healthSyncState(uid: number): HealthSyncStateResponse
export function unlinkHealthDevice(uid: number, deviceId: string, deleteData: boolean): { ok: true; deleted: { body: number; exercises: number; days: number } }
// reuse: tx/get/all/run (db), num/str/bad (lib/http), isDate/TIME_RE/todayIn/addDays (lib/dates),
//        getProfile/getWeights/weightOn/invalidateFrom (services/userdata), ACTIVITY_MAP/netKcal (standards/met)
```
`routes/app.ts` is thin: `appRouter.post("/health/sync", requireAuth, ah((req) => applyHealthSync(req.user!.id, req.body ?? {})))`.

### C.3 `GET /api/v1/health/sync/state` (requireAuth)
```jsonc
{ "timezone": "Asia/Shanghai", "server_today": "2026-10-03",
  "devices": [ { "device_id": "…", "device_name": "小林的 iPhone",
      "kinds": { "days": { "last_synced_at": "2026-10-03 01:02:03", "min_date": "2026-07-06", "max_date": "2026-10-03", "cursor": null },
                 "samples": { … }, "workouts": { … } } } ],
  "counts": { "days": 90, "body": 120, "workouts": 80 },
  "legacy_sources": { "apple_shortcut_days": 12, "apple_export_days": 300 } }
```
- `counts.days` = number of `health_day_snapshots` rows.
- `counts.body` = `body_metrics` with `source='healthkit'`.
- `counts.workouts` = `exercises` with `source='healthkit'`.
- `legacy_sources` = `activity_days` grouped by `source`, for `apple_shortcut` and `apple_export`.
- With no profile, `timezone` is `Asia/Shanghai` (it does not 400).

### C.4 `POST /api/v1/health/sync/unlink` (requireAuth)
Body `{ "device_id": string (required), "delete_data": boolean }`.
- **`delete_data` false:** delete this device's `health_sync_state` rows.
- **`delete_data` true:** in one transaction:
  1. `DELETE FROM body_metrics WHERE user_id=? AND source='healthkit'` and the same for `exercises`. The triggers write tombstones.
  2. `DELETE FROM health_tombstones WHERE user_id=?`, so a later re-link can import again.
  3. For each snapshot row: null every `activity_days` field whose value equals the snapshot's. Then delete the row if all 7 fields are null and its `source='healthkit'`.
  4. `DELETE FROM health_day_snapshots WHERE user_id=?` and all `health_sync_state` rows of the user.
  5. `invalidateFrom(uid, minAffectedDate)`.

  This removes **all** HealthKit data of the user, not per device; the UI copy says so.
- **Response:** `{"ok": true, "deleted": {"body": n, "exercises": n, "days": n}}`. Errors: `400 device_id 不能为空`.

### C.5 `POST /api/v1/account/delete`: in-app account deletion (App Store 5.1.1(v), RB-2)
- **Auth:** `requireAuth`.
- **Request:** `{"password": string}`. A POST body is used deliberately, because bodies on `DELETE` have no defined semantics and can be stripped by proxies.
- **Errors, in check order:** `400 密码不能为空` (`str(…, {name: "密码"})`), then `400 密码不正确` (`verifyPassword` fails).
- **Effect** (`services/accountDeletion.ts → deleteUserCompletely(uid)`):
  1. In one `tx()`:
     - `DELETE FROM body_metrics WHERE user_id=?` and `DELETE FROM exercises WHERE user_id=?`. These run first so the tombstone triggers see the parent row; this was verified.
     - `DELETE FROM users WHERE id=?`. `ON DELETE CASCADE` removes sessions, profile, grants (both directions), meals, meal_items, foods, activity, labs, ai_jobs, daily_scores, reports and all v3 tables. Other users' `meal_items.food_id` pointing at this user's foods become `NULL` (`ON DELETE SET NULL`).
  2. After commit, `fs.rmSync(path.join(config.uploadDir, String(uid)), {recursive: true, force: true})`.
  3. Respond `{"ok": true}`. Every token of the user is now invalid (sessions cascaded).
- **Queued AI jobs** for the user that still run will fail harmlessly: they update 0 rows or log an FK error.

### C.6 `GET /api/v1/auth/config` (public, no auth)
```json
{ "allow_registration": true, "invite_required": true, "min_password": 6, "server_version": "1",
  "features": ["health_sync", "account_delete", "token_refresh", "session_current"] }
```
- `invite_required = !!config.inviteCode`. The invite code itself is **never** returned.
- The app uses this to hide or show the invite field, show `当前站点已关闭注册`, and enable features. If it returns 404 on an old server, the app assumes `invite_required = true` and no features.

### C.7 `GET /api/v1/auth/sessions`: new `current` field
- **SQL:** add `token_hash` to the select. Map each row to `{id, kind, device_name, created_at, last_used_at, expires_at, current: row.token_hash === currentTokenHash(req)}` and drop `token_hash` from the output.
- **Order and other fields:** unchanged.
- **`currentTokenHash(req)`:** `sha256` of `presentedToken(req)?.token`, using the same cookie-first precedence as `userFromSession`.

### C.8 `POST /api/v1/auth/refresh`: rotate the app token
- **Auth:** `requireAuth`.
- **Rejection:** if `presentedToken(req)` is not a bearer token, or its session row's `kind != 'app'`, return `400 只有 App 令牌可以续期`.
- **Otherwise, in a tx:**
  - `createAppToken(uid, row.device_name ?? "App")`
  - `UPDATE sessions SET expires_at = <now + 24 h> WHERE token_hash = <old hash> AND expires_at > <now + 24 h>`: the old token stays valid for **≤ 24 h** (only shortened, never extended), so a response lost on a flaky network can be retried with it instead of forcing a logout. A token minted by a lost response is never used and shows up in 登录设备, where the user can revoke it.
- **Response:** `{"token": "nla_…", "expires_at": "<ISO>"}`.
- **Client use:** the app calls it at bootstrap and on every foreground when fewer than 30 days remain (§B.3); a single-flight guard prevents parallel rotations, and a response that arrives after a logout is dropped.

### C.9 OpenAPI additions (`server/src/openapi.ts`)
Add `OPS` entries (tag `App`, unless noted):
- `/auth/config` (`get`, auth `none`)
- `/auth/refresh` (`post`)
- `/account/delete` (`post`, body `{password}`)
- `/health/sync` (`post`, tag `身体与活动`, body `ref("HealthSyncRequest")`, response `ref("HealthSyncResponse")`)
- `/health/sync/state` (`get`)
- `/health/sync/unlink` (`post`)

Also:
- Add `current: {type: "boolean"}` to the `/auth/sessions` item schema.
- Add `external_id`, `source_name` to the `Exercise` and `BodyMetric` schemas, and `started_at`, `ended_at`, `hk_activity_type` to `Exercise`.
- Add the previously missing doc-only routes `DELETE /labs/{id}` and `GET /uploads/{id}`.
- New schemas: `HealthSyncRequest`, `SyncDay`, `SyncSample`, `SyncWorkout`, `HealthSyncResponse`, `HealthSyncState` (field lists exactly as §C.2–§C.3).

### C.10 Test plan (node:test, run by the existing `npm test` → `tsx --test test/*.test.ts`)
**Prerequisite:** Node ≥ 22.13 is not installed on this Mac. **`brew install node`** is required to run `npm install && npm test && npm run typecheck` in `aaaaa/`. Note it in the hand-off; **do not run it as part of the design**.

**`test/helpers/testApp.ts`** (not matched by `*.test.ts`):
- `makeTestApp()`:
  1. Sets `process.env.DATA_DIR = fs.mkdtempSync(os.tmpdir()/nl-test-)`, `SCHEDULER=false`, `AI_PROVIDER=mock`, `INVITE_CODE=test-invite`, `ALLOW_REGISTRATION=true`.
  2. **Then** dynamically imports `express` and the routers, so `config`/`db` pick up the temp dir. Test files must not statically import `src/*`.
  3. Mounts `/api/v1` and `/api` in the same order as `index.ts`: docs, account, **app**, body, log, reports, then the `接口不存在` 404 handler.
  4. Copies the `index.ts` error handler (`HttpError` → status; `entity.parse.failed` → 400; `LIMIT_FILE_SIZE` → 413; else 500).
  5. Listens on port 0 and returns `{ base, close(), db }`.
- Helpers:
  - `register(base, username)`: `POST /auth/register` with `device_name` and the invite code, returning the token.
  - `withProfile(base, token)`: `PUT /profile` with `{sex:"male", birth_date:"1990-01-01", height_cm:175, weight_kg:70, timezone:"Asia/Shanghai"}`.
  - `api(base, token)`: a fetch wrapper.

**`test/healthsync.test.ts`**
1. **Migration.** `_migrations` max = 3. `PRAGMA table_info` shows the new columns. The 4 new tables and 2 triggers exist.
2. **Days insert.** The row has `source='healthkit'` and the values; the snapshot row exists. `GET /activity` returns them. `GET /day/{date}` has `score.energy.activeSource == "device"` when `active_kcal > 0`.
3. **Idempotency.** Re-posting an identical payload gives `days.unchanged` = N, `upserted` = 0, `invalidated_from` null, and the `daily_scores` row for that date is still present.
4. **Manual protection.**
   - Setup: sync steps 8000 / sleep 7; then `PUT /activity/{date}` with steps 8000 and sleep 6.5, which makes the row manual.
   - Sync steps 9000 / sleep 7.2. Expected: steps becomes 9000 (it was unchanged from the snapshot); sleep stays 6.5 and appears in `kept_manual`; `source` stays `manual`.
   - The same payload with `overwrite_manual: true` gives sleep 7.2.
5. **Manual clear wins.** `PUT /activity` nulls sleep that HealthKit had written; the next sync with sleep keeps null and reports `kept_manual`.
6. **`clear`.** On a healthkit row, `clear:["sleep_hours"]` sets it to NULL.
7. **Legacy overwrite.** `/health/ingest` (apple_shortcut) steps 5000, then sync steps 6000 → 6000, `source='healthkit'`.
8. **Samples.** Insert a weight; re-send gives `unchanged`; the same uuid with a new value gives `updated` (one row only). BP without dbp is rejected while the rest of the batch succeeds. Body fat 1.0 is rejected (`体脂率不能小于 2`).
9. **Tombstone.** `DELETE /body/{id}` of a synced sample, then re-send → `skipped_tombstoned: 1`; no row is re-created.
10. **Workouts.** `kcal == round((met−1)·weight·min/60)` using the latest weigh-in. `in_device` stored as 1. An unknown key falls back to `other_moderate`. Re-send is unchanged. A manual `POST /exercises` (same date, `run_10kmh`, duration within 20%) followed by a sync of a run workout gives `possible_duplicates` length 1, and both rows exist.
11. **`deleted`.** Removes body and exercise rows by uuid; `not_found` counts unknown uuids; the tombstone exists.
12. **Scoring integration.** After syncing `active_kcal` 500 and an `in_device` workout, `/day` `energy.active == 500` (the workout is not double-counted) and `exerciseKcal` includes the workout. After syncing a weight, `/day.targets.weightKg` equals it. After syncing BP 3×, LE8 `bp` points are non-null.
13. **Errors.** No profile → 400 `请先完善个人档案`. Missing `device_id` → 400. `days` length 401 → 400. A `nl_` personal token → 401.
14. **State.** `GET /health/sync/state` lists the device with `days.max_date` and the counts; `legacy_sources` counts the ingest day.
15. **Unlink.** `delete_data: true` removes the healthkit body and exercise rows, clears tombstones and the snapshot, nulls only the fields that matched the snapshot, and a subsequent re-sync re-imports. `delete_data: false` removes only that device's state.
16. **Web regression.** `GET /body` rows still contain every pre-existing key with the same values; the only new keys are `external_id`/`source_name` = null. `POST /body`, `/activity/commit`, `/health/ingest` and `/health/import` behave as before; for example, ingest weight still inserts an `apple_shortcut` row.

**`test/appAccount.test.ts`**
1. `GET /auth/config` without auth returns `invite_required: true`, `features` includes `health_sync`, and there is no `invite` value in the body.
2. Two tokens for one user: `GET /auth/sessions` with token A marks exactly A's row `current: true`.
3. `POST /auth/refresh` returns a new token: the old token gets 401 on `/auth/me`, the new one gets 200, and the `device_name` is preserved. A web-cookie session (`/auth/login`) gets 400.
4. `POST /account/delete`: a wrong password gives 400 `密码不正确` and the user still exists. With the correct password: 200; the `users` row is gone; a healthkit body row, tombstones and snapshots are gone (no FK error); the uploads dir is removed; the token gets 401. Another user's `meal_items.food_id` that referenced the deleted user's public food becomes `null`.
5. Plain `DELETE FROM users` (cascade without pre-deletes) succeeds when the user has `external_id` rows, which checks the trigger guard.
6. `buildOpenApi("http://x").paths` contains `/health/sync`, `/health/sync/state`, `/health/sync/unlink`, `/auth/config`, `/auth/refresh`, `/account/delete`.

The existing `test/scoring.test.ts` must still pass unchanged, and `npm run typecheck` (tsc) must pass.

### C.11 Deployment
1. Back up `data/nutrilog.db` and `data/uploads/`.
2. Deploy the server code and restart. Migration v3 runs automatically in a transaction; if it fails, the server refuses to start and the DB is unchanged.
3. Smoke test:
   - `GET /api/v1/auth/config` responds.
   - The web UI loads and works as before (manual check of Today, Body and Log Meal).
4. Then release the iOS build. Older servers degrade gracefully: the app sees `.unsupportedByServer` and hides sync and account deletion with a message.

### C.12 Server changes considered and rejected
| Proposal (source) | Reason rejected |
|---|---|
| Fix `/health/ingest` (dedupe weight, stand hours, ranges) (body §12.6, web1 §9.1) | Changes behaviour the iPhone Shortcut users rely on. Superseded by the new `/health/sync`. |
| Prefer Bearer over cookie in `userFromSession` (auth §8.6) | Changes auth precedence for every client. The iOS client disables cookies, which removes the need. |
| `GET /meals?start&end` (meals §7.3) | Not needed for parity: meals come from `/day/{date}`. |
| `PATCH /meals/{id}` / photo editing (meals §7.3) | Would diverge from web behaviour (PUT ignores photos). iOS keeps parity; photos are fixed after the first save. |
| `DELETE /ai/jobs/{id}` cancel + `queue_position` (meals §7.3) | Touches the in-memory queue; the client-side cancel (stop polling) is enough. |
| Map multer count/field errors to 400 (meals §7.3) | Edits the shared error handler; the client never sends more than 6 files or a wrong field name. |
| Pass `category` through `/preview` (meals §7.3) | Changes the numbers the **web** preview shows (a behaviour change). |
| `GET /uploads/{id}?user=` for shared viewers (rep §16 P1) | Privacy-sensitive, and the web has the same limitation. Member views hide photos. |
| `GET /standards/rules` (rep §16 P2) | The texts are static; WP8 embeds them verbatim (`StandardsRulesText.swift`). |
| `/standards/dri?format=rows` (rep §16 P3) | The client orders rows with `Vocab.intakeOrder`/`upperOrder`. |
| `/trends?fields=` + gzip (rep §16 P4) | gzip needs a new dependency and changes every web response; the client decodes off the main actor and limits 全部 to about 3 years. |
| `ORDER BY created_at DESC` in the `/period` summary lookup (web2 §7.7) | A real bug, but it changes what the **web** shows. Reported to the owner as a follow-up; the iOS app shows whatever `/period` returns. |
| `POST /period/summary` 400 when the provider is mock (rep §16 P6) | A behaviour change; the client gates on `me.ai.provider != "mock" && daysLogged > 0`, as the web does. |
| `revoke_others` on `/auth/password` (auth §8.5) | The 登录设备 screen lets users revoke sessions manually. |
| Accept HEIC uploads (meals §7.3) | The client always transcodes to JPEG. |
| `DELETE /account` with a body (index §2.4) | Replaced by `POST /account/delete` (same semantics; safer with a body). |

---

### C.13 `GET/PUT /api/v1/ai/consent`: in-app third-party AI consent (migration v4)
- **Migration v4:** `CREATE TABLE ai_consent (user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, granted INTEGER NOT NULL, updated_at TEXT NOT NULL DEFAULT (datetime('now')))`.
- **`GET /ai/consent`** (requireAuth) → `{granted: true|false|null, updated_at}`; `null` = never answered in the app.
- **`PUT /ai/consent {granted: boolean}`** (requireAuth) → `{ok:true}`; anything but a boolean → `400 granted 必须是 true 或 false`.
- **`/auth/config` features** gain `"ai_consent"`.
- **Scheduler gate** (`schedulerMayUseAI`): the automatic weekly/monthly AI summary runs only when the user granted consent; a user who never answered keeps the old behaviour unless they have synced through HealthKit (`health_sync_state` rows, which only the app creates). Web-only users are unaffected.
- **Client:** the app asks once per server and account before the first AI request (AI 分析, AI 查询营养信息, AI 识别, 生成点评; not for a mock provider), stores the answer locally and mirrors it here; 更多 → 外观 → AI has the toggle (RB-5).

## D. Feature parity matrix

Every web feature (index §3; web1; web2) maps to an iOS file and owner. "=" means same behaviour and wording as the web spec section; deviations are stated.

| # | Web feature (spec) | iOS screen / file (WP) | Notes |
|---|---|---|---|
| 1 | Login (web2 §5.8; auth §3.3) | `Features/Auth/LoginScreen.swift` (WP1) | Uses `POST /auth/token` + `device_name`, never `/auth/login`. Adds the 服务器 row. |
| 2 | Register + invite code (web2 §5.8; auth §3.2) | `LoginScreen` register mode (WP1) | Invite field hidden if `authConfig.invite_required == false`. Shows `当前站点已关闭注册` if registration is not allowed. |
| 3 | Onboarding + ProfileForm (web2 §5.6–5.7) | `OnboardingScreen`, `Profile/ProfileFormView` (WP1) | + `HealthPrefillButton` (WP9) for sex, birth date, height and weight. Time zone defaults to `TimeZone.current.identifier`. |
| 4 | App shell, sidebar, bottom bar (web2 §2) | `App/MainTabView`, `RootView` (WP0-B) | 5-tab layout with an action tab in the centre (§B.2) |
| 5 | Toasts, loading, empty states (web2 §1.8, §3.4) | `DesignSystem` (WP0-C) | = |
| 6 | Today score card: ring, TotalParts, HEI and MAR meters, hazard count, completeness banner (web1 §4.3 A1) | `TodayScoreCard` (WP2) | = (`评分依据` → Standards rules tab) |
| 7 | Energy card: tiles, bars, foot text, macro bar (A2) | `TodayEnergyCard` (WP2) | = |
| 8 | Highlights 今日要点 (B1) | `TodayHighlightsCard` (WP2) | = |
| 9 | Key limits 关键指标 meters with marks (B2) | `TodayKeyLimitsCard` (WP2) | = |
| 10 | LE8 card + MEPA modal; WCRF card (C) | `Le8Card`, `MepaSheet`, `WcrfCard` (WP0-C), used by WP2/5/6 | = |
| 11 | Hazards card (D) | `TodayHazardsCard` + `HazardResultRow` (WP2/WP0-C) | = |
| 12 | Meals list, water ±250 ml, edit/delete meal (E1) | `TodayMealsCard` (WP2) | Delete uses a destructive confirmation dialog; the water pseudo-meal is hidden. Photos are not shown on Today (the web doesn't show them either). |
| 13 | Activity card + 填写 / AI 识别截图 (E2) | `TodayActivityCard` (WP2) → `ActivityRecognizerSheet` (WP4) | The empty-state hint replaces the Shortcuts sentence with HealthKit wording |
| 14 | Detail tabs: 全部营养素 / HEI-2020 / 评分明细 (F) | `TodayDetailTabs` (WP2) | Nutrient table rendered as two-line list rows (web1 §4.3 F note) |
| 15 | Member read-only day `/u/:username` (web1 §4; rep §1) | `TodayScreen(member:)` (WP2) | `@{username} 的记录`, `只读视图（对方开启了共享）`, `看趋势`. No edits; photos hidden; `full == false` hides meals and messages. |
| 16 | Log Meal: input, photos, AI analyse, staged progress (web1 §5.2) | `LogMealScreen`, `LogMealInputCard`, `LogMealAnalyzingCard` (WP3) | + camera capture, HEIC→JPEG, job resume |
| 17 | Follow-up questions, assumptions, sources (web1 §5.4) | `LogMealDraftInfo` (WP3) | = |
| 18 | Review: ItemEditor, rescale, adjust panel (category, NOVA, description, nutrients, groups, hazards) (web1 §5.3; meals §4) | `ItemEditorView`, `ItemAdjustPanel` (WP3) using `ItemMath` (WP0-A) | = (`food_id` unlink rules) |
| 19 | Food picker 从食物库添加 (web1 §5.6) | `FoodPickerSheet` (WP3) | = |
| 20 | Save to library 存入食物库 (web1 §5.7) | `SaveFoodSheet` (WP3) | = |
| 21 | Quick foods 常用食物 (web1 §5.2) | `QuickFoodsCard` (WP3) | = |
| 22 | Merge preview 合并预览 (web1 §3.7; 400 ms debounce) | `ImpactPreviewCard` (WP0-C) driven by `LogMealModel` (WP3) | = |
| 23 | Save / edit meal (web1 §5.5) | `LogMealModel.save()` (WP3) | Edit loads `/day/{date}`; photos are not round-tripped (server ignores them on PUT) |
| 24 | ActivityRecognizer: manual and AI, photos, draft edit, workouts, preview (350 ms), commit (web1 §6) | `ActivityRecognizerSheet`, `ActivityRecognizerModel`, `WorkoutEditorRow` (WP4) | = (+ an iOS hint that commit can't clear fields) |
| 25 | Body: weight form, history, delete (web1 §7.2 1a) | `BodyWeightCard` (WP4) | Swipe-to-delete with no confirmation, as on the web |
| 26 | 近 90 天体重 chart (1b) | `BodyWeightChartCard` (WP4) | Swift Charts `PointMark` + `LineMark` |
| 27 | Exercises: manual add, AI entry, `in_device` toggle, delete (2a) | `BodyExercisesCard` (WP4) | = |
| 28 | Steps & activity form `PUT /activity` + 30-day steps chart (2b) | `BodyActivityCard` (WP4) | Local edits reset on date change (web quirk fixed). When sync is on, shows the note `开启 Apple 健康同步后，你手动修改的数值会被保留，不会被同步覆盖`. |
| 29 | Labs with mmol/mg toggle, table, delete (Row 3) | `BodyLabsCard` (WP4) | = (×38.67 / ×18) |
| 30 | 连接苹果健康 card: personal token + Shortcut guide + export import (Row 4) | **Replaced by** `HealthSyncScreen` (WP9), linked from `BodyHealthSyncRow` (WP4) and 更多 | Personal-token management is kept under 高级. export.zip import is **not ported**; native sync supersedes it. |
| 31 | Trends: ranges + custom, bucketing, summary tiles (web2 §5.1) | `TrendsScreen`, `TrendsModel`, `TrendsBucketing`, `TrendsSummaryTiles` (WP5) | = (incl. the HEI null-as-0 quirk) |
| 32 | Charts A–D + table toggle | `TrendsScoreChart`, `TrendsEnergyChart`, `TrendsWeightChart`, `TrendsCategoryChart` (WP5) | = |
| 33 | Nutrient explorer with target lines | `TrendsNutrientExplorer` (WP5) | The picker stays visible in table mode (web bug fixed) |
| 34 | Score calendar heatmap (span ≥ 45) | `TrendsScoreCalendar` (WP5) | Custom grid; horizontal scroll |
| 35 | LE8/WCRF for the period, pass rates, checks, hazard totals | `TrendsPassRatesCard`, `TrendsChecksCard`, `TrendsHazardTable` + shared cards (WP5) | = |
| 36 | Member trends `/u/:username/trends` | `TrendsScreen(member:)` (WP5) | No target lines for members |
| 37 | Reports week/month, nav, tiles, sections (web2 §5.2) | `ReportsScreen`, `ReportsSections` (WP6) | Errors shown as a banner (the web shows a blank page) |
| 38 | AI 点评 generate / poll / regenerate (web2 §5.2.5) | `ReportsAISummaryCard` (WP6) | Gated on `!app.isMockAI && daysLogged > 0` |
| 39 | Community cards, sparkline, streak, access chips (web2 §5.4) | `CommunityScreen`, `CommunityUserCard` (WP6) | Long-press tooltip; cached for 60 s |
| 40 | Settings: profile, share (member picker), appearance, AI banner, password, logout, quick links (web2 §5.5) | `MoreScreen` + `More/*` (WP1) | = |
| 41 | Foods: search/scope, cards, detail table, delete/edit, AI lookup with photos, editor (web2 §5.9; meals §6.5) | `FoodsScreen`, `FoodsDetailView`, `FoodsLookupSheet`, `FoodsEditorSheet` (WP7) | Full-replace PUT round-trips every field |
| 42 | Standards 7 tabs + `?tab=` deep link (web2 §5.10; rep §9) | `StandardsScreen(initialTab:)` + tabs (WP8) | Rules text embedded verbatim |
| 43 | Shortcut personal token (auth §3.13) | `HealthSyncScreen` 高级 (WP9) | = strings |
| **iOS only** | | | |
| 44 | HealthKit auto-sync of days, samples, workouts, deletions; manual-edit protection | `Core/Health/*`, `HealthSyncScreen` (WP9) + server §C.2 | |
| 45 | Background sync (observer + BG refresh) | `HealthBackground` (WP9), `AppDelegate` (WP0-B) | |
| 46 | Camera capture for meals, labels and screenshots | `CameraPicker`, `PhotoUploadStrip` (WP0-B) | Used by WP3, WP4, WP7 |
| 47 | Onboarding prefill from Health | `HealthPrefillButton` (WP9) | |
| 48 | 登录设备 list and revoke | `DevicesScreen` (WP1) | `current` flag (§C.7), with a fallback heuristic on old servers |
| 49 | 删除账号 | `DeleteAccountScreen` (WP1) + §C.5 | App Store 5.1.1(v) |
| 50 | 服务器 address setting | `ServerAddressSheet`, `ServerSettingsScreen` (WP1) | |
| 51 | 历史报告 | `ReportHistoryScreen` (WP6) via `GET /reports` | Tapping a row opens that range in Reports |
| 52 | Token auto-refresh | `AppState` (WP0-B) + §C.8 | |
| 53 | Pull-to-refresh, AI job resume after relaunch | Today/Trends/Body/Reports/Foods (WP2/5/4/6/7); `PendingJobStore` (WP0-B) + WP3 | |

---

## E. Implementation partition

### E.1 Phases and dependency graph
```
            ┌────────────────────────── WP-S Server (TypeScript; independent; start day 1) ──────────────┐
            │                                                                                            │ deploy before device QA of WP9 / WP1-delete
Phase 0:  WP0-A Project+Models+Util ──► WP0-B Networking+Auth+App shell+Media+stubs ─┐
                                   └──► WP0-C DesignSystem+shared health cards ──────┴─► GATE-0 (verify.sh green)
Phase 1 (all parallel after GATE-0):
          WP1 Auth/Onboarding/More   WP2 Today   WP3 LogMeal   WP4 Body+Recognizer   WP5 Trends
          WP6 Reports+Community      WP7 Foods   WP8 Standards WP9 HealthKit
Phase 2:  GATE-FINAL: verify.sh green on the merged tree; owners fix their own files.
```
- **WP0-B and WP0-C** start as soon as WP0-A's `Core/Models` and `Core/Util` exist. They depend on each other only through §E.3 names (`ToastCenter` is WP0-C, used by `AppState` in WP0-B), and GATE-0 compiles them together.
- **Phase-1 cross-WP use is only through seeded stubs.** For example, WP2 presents WP4's `ActivityRecognizerSheet`, and WP1 embeds WP9's `HealthPrefillButton`. Each WP can therefore compile and pass `verify.sh` on its own branch.

### E.2 Work packages
**WP0 = Core foundation**: project file, App entry, networking, all models, auth, design system and formatting. It is delivered as three sub-packages (WP0-A, WP0-B, WP0-C) so that each stays at a size one engineer can complete. **Every Phase-1 WP depends on all of WP0 (GATE-0).**

Sizes are estimated lines of Swift. Each WP must leave `scripts/verify.sh` green.

**WP0-A: Project, models and utilities** (about 1,700 lines, mostly mechanical; deps: none)
- **Files:**
  - `NutriLog.xcodeproj/project.pbxproj`, `NutriLog/Info.plist`, `NutriLog/NutriLog.entitlements`, `Resources/**`
  - `Core/Models/*` (15 files), `Core/Util/*` (8 files)
  - `scripts/verify.sh`, `scripts/lint.sh`, `scripts/logic-tests.sh`, `scripts/make-icon.swift`
  - `LogicTests/Harness.swift`, `LogicTests/Core/*`
- **Scope:**
  - The §A.5–A.6 files verbatim.
  - Every model in §E.3.1, plus the vocab **contents** (fill every array from the cited spec sections).
  - `Food.toInput()`, `FoodInput.blank()` (meals §6.5 defaults), `FoodInput(draft:)` (aliases array; `source_urls = draft.sources`).
  - Util implementations: `fmt` exactly as §E.3.2; `LocalDay` per web2 §1.4 and web1 §0.2; `ItemMath` per meals §4.1–4.3 (NaN-safe).
  - Logic tests:
    - `fmt` table: `1568→"1,568"`, `39.2(1)→"39.2"`, `78(1)→"78"`, `2.5→"3"`, `-795→"-795"`, `nil→"—"`.
    - `dateLabel`, `weekStart` (Monday), `monthEnd`, `addMonths`.
    - `rescale` / `toDraft` / `setNutrient` unlinks `food_id`.
    - Decoding a hand-written `DayResponse` fixture with absent optional keys and 0/1 flags.
- **Done when:**
  - `verify.sh` steps 1–3 pass on Models and Util alone.
  - The unsigned `xcodebuild` of the empty app succeeds.

**WP0-B: Networking, auth, app shell, media and stubs** (about 1,500 lines; deps: WP0-A, plus WP0-C names)
- **Files:** `App/*`, `Core/Networking/*`, `Core/Auth/*`, `DesignSystem/Media/*`, plus the **seeded stubs** listed in §E.3.6 at their final paths (`Features/**/…Screen.swift`, `Core/Health/HealthSyncService.swift`, `Features/HealthSync/HealthPrefillButton.swift`).
- **Scope:**
  - Everything in §B.2–§B.4.
  - `APIClient` with every method in §E.3.3. Each maps 1:1 to a spec endpoint (method, path, query, body), as given in the comment above each group.
  - `AppState` exactly per §B.3.
  - `ImageTranscoder` (orientation-correct JPEG); `PhotoCache` (LRU about 50 MB); `PhotoUploadModel` (cap 6, transcode, upload in one request, error callback); `PhotoUploadStrip` (72×72 thumbnails, × remove, `PhotosPicker` + 拍照 menu; adding is disabled at the limit); `CameraPicker`.
- **Done when:**
  - The app launches to Login.
  - With a valid account it shows the 5 tabs with stub screens.
  - 401 returns to Login.
  - The server address can be changed.

**WP0-C: Design system and shared health cards** (about 1,500 lines; deps: WP0-A)
- **Files:** `DesignSystem/**` except `Media/`.
- **Scope:** §B.6, with every component in §E.3.4 matching web1 §3 and web2 §3–§4 (sizes, colours, maths, strings), plus SwiftUI `#Preview`s fed by fixture data.
- **Done when:** previews render all components in light and dark.

**WP1: Auth, onboarding, profile and the 更多 tab** (about 1,300 lines; deps: GATE-0. Uses the WP9 stub `HealthPrefillButton`.)
- **Files:** `Features/Auth/*`, `Features/Profile/*`, `Features/More/*`
- **Spec:** web2 §5.5–5.8; auth §3, §5, §6
- **Scope:**
  - Login/register (§D rows 1–2), including the 服务器 sheet.
  - Onboarding.
  - `ProfileFormView`: every field, the conditional fields, the client validation in auth §9, and sending the **full** profile.
  - `MoreScreen` hub (§B.2).
  - `ProfileSettingsScreen` (`建档体重` label and help text).
  - `ShareSettingsScreen`: sends **all five fields**; member picker from `GET /users`.
  - `AppearanceScreen`: theme Seg plus the AI banner text.
  - `PasswordScreen`: trims the old password.
  - `DevicesScreen`:
    - Sessions list.
    - "本机" uses `current == true`, falling back to the newest `app` row with our `device_name`.
    - Swipe to revoke with confirmation; revoking the current session logs out.
    - Expired rows are greyed.
    - Timestamps are parsed in UTC and shown in local time.
  - `ServerSettingsScreen`.
  - `DeleteAccountScreen`:
    - Warning copy: `删除账号会永久删除你的所有饮食、身体、运动、化验与同步数据，且无法恢复。`
    - Password field, then `app.deleteAccount(password:)`.
    - `.unsupportedByServer` shows `服务器暂不支持在 App 内删除账号，请联系管理员`.
- **Done when:** every row of §D marked WP1 works against the live server, except deletion, which needs WP-S.

**WP2: Today (own and member)** (about 1,400 lines; deps: GATE-0. Uses the WP4 stub `ActivityRecognizerSheet`.)
- **Files:** `Features/Today/*`
- **Spec:** web1 §3–§4; rep §1–§5, §17.2
- **Scope:**
  - Sections A–F in display order, single column.
  - `DateNav` bound to `router.todayFocusDate`.
  - `.refreshable`; reload on `dataVersion`.
  - Water ± with `POST /water`.
  - Meal delete with confirmation; meal edit routes to Log Meal.
  - Activity card with exercise and body rows.
  - Detail tabs.
  - Member mode (§D row 15).
  - Error banner; keep the previous day visible while reloading.

**WP3: Log Meal** (about 1,500 lines; deps: GATE-0)
- **Files:** `Features/LogMeal/*`
- **Spec:** web1 §5; meals §2–§4, §6.1–§6.2
- **Scope:**
  - Phases input → analysing → review.
  - Photos (`PhotoUploadStrip`).
  - `POST /ai/meal` + `JobPoller` + `JobProgressView` (staged hints <8/<30/<70 s). Save a `PendingJob` with context `{date, time, meal_type, text, photos}`; on open, offer `继续等待上次的 AI 分析` if a pending meal job is under 30 minutes old.
  - Follow-up re-analysis; the re-analysis item-merge rule (keep `food_id` items unless it is a follow-up; de-duplicate by `food_id`).
  - `ItemEditorView` + `ItemAdjustPanel` using `ItemMath`.
  - `FoodPickerSheet` (200 ms debounce), `SaveFoodSheet`, `QuickFoodsCard` (first 12 of `GET /foods?scope=all`).
  - Preview with a 400 ms debounce; errors hide it.
  - Save via POST or PUT, then the toast `已保存，评分已更新` and `router.showToday(date:)`.
  - Edit mode loads `/day/{date}` and maps items with `ItemMath.toDraft`.
  - Presented as a sheet: `LogMealScreen(request:)`, with a 取消 toolbar button that confirms if there are unsaved items.

**WP4: Body + ActivityRecognizer** (about 1,500 lines; deps: GATE-0)
- **Files:** `Features/Body/*`
- **Spec:** web1 §6–§7; body §3–§4, §11
- **Scope:**
  - Weight card and history.
  - 90-day weight chart from `/trends`.
  - Exercises card (manual add with `in_device = day.active_kcal > 0`; `PATCH` toggle; delete).
  - Activity form (`PUT /activity` with all 7 fields, empty = clear) and the 30-day steps bar chart.
  - Labs card with the unit toggle.
  - `BodyHealthSyncRow`: shows `app.healthSync.status` and pushes `.healthSync`.
  - `ActivityRecognizerSheet` (manual and AI modes):
    - AI uses `POST /ai/activity` + `JobPoller` (hint `正在识别… 读取截图通常需要 20–60 秒`).
    - Draft editing and workouts (`WorkoutEditorRow`; kcal estimate uses `profile.weight_kg ?? 65`).
    - Preview with a 350 ms debounce.
    - `POST /activity/commit` with `source` = mode.
    - The `date_from_image` banner.
    - Header date picker (max today).

**WP5: Trends** (about 1,400 lines; deps: GATE-0)
- **Files:** `Features/Trends/*`, `LogicTests/Trends/*`
- **Spec:** web2 §4, §5.1; rep §6, §10
- **Scope:**
  - Range Seg (7 options, wrapping) plus custom dates.
  - Three parallel loads (`/trends`, `/period` clamped to 400 days, `/profile/targets` for own data only).
  - `TrendsBucketing`, pure: day/week/month, labels, averages, quirks.
  - The 11 sections (§D rows 31–36), with a table toggle on every chart card, null gaps, and target `RuleMark`s with trailing annotations.
  - Calendar heatmap.
  - Opacity 0.55 while reloading.
  - Logic tests for bucketing: week key on Monday, month label `25/3月`, a null HEI counted as 0, steps averaged over days with steps.

**WP6: Reports, Community, report history** (about 1,100 lines; deps: GATE-0)
- **Files:** `Features/Reports/*`, `Features/Community/*`
- **Spec:** web2 §5.2–5.4; rep §6–§8, §11, §17.4
- **Scope:**
  - Week/month Seg; default anchor last Monday for weeks and today for months.
  - Previous/next, with next disabled when `end >= today`.
  - Every section in web2 §5.2.4.
  - AI summary: `POST /period/summary` + `JobPoller`, then refetch `/period`; `Claude 正在阅读本期评分数据并撰写点评…`.
  - Community grid as a single-column list (sparkline, streak, chips, tap routing).
  - `ReportHistoryScreen` (from a toolbar button `历史报告`): `GET /reports`; a row shows period kind, range, LE8 score and AI headline; tapping opens Reports at that range. `ReportsScreen` must accept an internal init `ReportsScreen(start:end:kind:)` in addition to the stub's `init()`.

**WP7: Foods** (about 900 lines; deps: GATE-0)
- **Files:** `Features/Foods/*`
- **Spec:** web2 §5.9; meals §1.12, §1.14, §2.15–2.19, §6.5
- **Scope:**
  - List with 250 ms debounced search and the `全部可用`/`我创建的` scope.
  - Cards; detail (table with DV%, `标签` chips, sources).
  - Delete (confirmation) and edit (full-replace PUT via `food.toInput()`).
  - AI lookup sheet (name, brand, note, photos; `POST /ai/food` + poller; result opens the editor prefilled through `FoodInput(draft:)`).
  - Editor: main vs. all 43 nutrients, `显示全部 43 项`.

**WP8: Standards** (about 800 lines; deps: GATE-0)
- **Files:** `Features/Standards/*`
- **Spec:** web2 §5.10; rep §9, §17.7
- **Scope:**
  - Scrollable tab bar of 7 tabs, starting at `initialTab`.
  - 我的个性化目标 (`/profile/targets` + meta).
  - DRI table with the RDA/AI vs UL Seg, sticky first column (use `ScrollView([.horizontal])` with a pinned name column) and rows ordered by `Vocab.intakeOrder`/`upperOrder`.
  - Hazards cards plus the info-only table.
  - HEI table, MET table.
  - 评分规则: the full text of rep §9.9, verbatim, in `StandardsRulesText.swift`.
  - 资料来源 list that opens URLs in Safari (`Link`).

**WP9: HealthKit sync** (about 1,500 lines; deps: GATE-0, plus WP-S deployed for end-to-end QA)
- **Files:** `Core/Health/*` (owns the seeded `HealthSyncService.swift`), `Features/HealthSync/*` (owns the seeded `HealthSyncScreen.swift` and `HealthPrefillButton.swift`), `LogicTests/Health/*`
- **Spec:** body §8, §12; this document §B.5, §C.2–§C.4
- **Scope:** everything in §B.5.
- **Logic tests:**
  - `SleepAggregator`: overlapping sources are unioned; a Watch preference; the 18:00 window split; `inBed` fallback; `nil` when empty.
  - `WorkoutMapper`: speed buckets and the indoor/open-water rules.
  - The `in_device` rule.
  - `DayAggregator` `clear` computation.
- **Device QA:** enable sync on an iPhone with Watch data; compare a day's steps and active energy with the Health app; delete a weight in Health and see it disappear; edit sleep on the web and see it kept.

**WP-S: Server** (TypeScript, about 600 lines of source plus about 450 of tests; deps: none)
- **Files:** exactly the table in §C.0.
- **Done when:**
  - `npm test` and `npm run typecheck` pass (needs `brew install node`).
  - The web is checked manually: Today, Log Meal, Body and Trends look and behave unchanged.

### E.3 Shared interfaces (the contract; compiled clean in Swift 6, §0)
These declarations are **normative**:
- **Names, stored properties, initialisers and method signatures must be exactly as written.**
- Bodies shown as `fatalError()` or `{}` are placeholders for the owner to implement.
- Owners may add members, extensions and private helpers, but must not rename or remove anything below.
- Where an array or dictionary literal is shown empty in `Vocab`, WP0-A fills it from the cited spec section.

#### E.3.1 Models: `Core/Models/*` (WP0-A), Foundation only
Split into files per §B.1; this is the concatenated content.
```swift
import Foundation

// MARK: - Common (meals §0.5, rep §0.5–0.8)
typealias Vec = [String: Double]
extension Dictionary where Key == String, Value == Double {
    /// Missing keys read as 0 (server always sends every key, but be tolerant).
    func v(_ key: String) -> Double { self[key] ?? 0 }
}
enum ScoreStatus: String, Codable, Sendable, CaseIterable {
    case good, ok, warn, bad, info
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScoreStatus(rawValue: raw) ?? .info
    }
}
struct KeyZh: Codable, Sendable, Hashable { let key: String; let zh: String }
struct OkResponse: Decodable, Sendable { let ok: Bool }
struct IdResponse: Decodable, Sendable { let id: Int }
struct JobCreated: Decodable, Sendable { let job_id: String }
enum JobStatus: String, Codable, Sendable { case queued, running, done, error }
struct Job<T: Decodable & Sendable>: Decodable, Sendable {
    let id: String; let kind: String; let status: JobStatus; let error: String?; let result: T?
}
struct SourceLink: Codable, Sendable, Hashable { var title: String?; var url: String }
struct HealthPing: Decodable, Sendable { let ok: Bool; let version: String }
struct EmptyBody: Encodable, Sendable {}

// MARK: - Account (auth §3–4)
struct User: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let username: String; let display_name: String; let avatar_color: String
    let share_mode: String; let share_detail: String; let api_token_hint: String?
    let share_with: [Int]?
}
struct AIInfo: Codable, Sendable, Hashable { let provider: String; let model: String; var isMock: Bool { provider == "mock" } }
struct ConditionDef: Codable, Sendable, Hashable, Identifiable { let key: String; let zh: String; let effect: String; var id: String { key } }
struct Profile: Codable, Sendable, Equatable {
    var sex: String; var birth_date: String; var height_cm: Double; var weight_kg: Double
    var activity_level: String; var goal: String; var goal_rate_kg_week: Double; var target_weight_kg: Double?
    var physiology: String; var sodium_mode: String; var conditions: [String]; var timezone: String
    var nicotine: String; var secondhand_smoke: Bool
    static func newDefault(timezone: String) -> Profile {
        Profile(sex: "male", birth_date: "1995-01-01", height_cm: 170, weight_kg: 65, activity_level: "low_active", goal: "maintain",
                goal_rate_kg_week: 0.5, target_weight_kg: nil, physiology: "none", sodium_mode: "cdrr", conditions: [],
                timezone: timezone, nicotine: "unknown", secondhand_smoke: false)
    }
}
struct Me: Codable, Sendable { let user: User; let profile: Profile?; let today: String; let ai: AIInfo; let conditions: [ConditionDef] }
struct LoginBody: Encodable, Sendable { let username: String; let password: String; let device_name: String }
struct RegisterBody: Encodable, Sendable { let username: String; let password: String; let display_name: String; let invite_code: String; let device_name: String }
struct TokenResponse: Decodable, Sendable { let token: String; let expires_at: String; let user: User? }
struct SessionRow: Decodable, Sendable, Identifiable, Hashable {
    let id: Int; let kind: String; let device_name: String?; let created_at: String?; let last_used_at: String?; let expires_at: String
    let current: Bool?            // S7 (new server field); nil on old servers
}
struct SettingsBody: Encodable, Sendable { var display_name: String; var avatar_color: String; var share_mode: String; var share_detail: String; var share_with: [Int] }
struct PasswordBody: Encodable, Sendable { let old_password: String; let new_password: String }
struct ProfileSaveResponse: Decodable, Sendable { let ok: Bool; let profile: Profile }
struct PersonalTokenResponse: Decodable, Sendable { let token: String }
struct AuthConfig: Decodable, Sendable { let allow_registration: Bool; let invite_required: Bool; let min_password: Int; let server_version: String; let features: [String] }
struct DeleteAccountBody: Encodable, Sendable { let password: String }
struct RecentScore: Codable, Sendable, Hashable { let date: String; let score: Double? }
struct CommunityUser: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let username: String; let display_name: String; let avatar_color: String
    let is_me: Bool; let shared_with_me: Bool; let share_detail: String; let last_log_date: String?
    let streak: Int; let recent: [RecentScore]
}

// MARK: - Targets (auth §4.6, rep §4)
struct IntakeTarget: Codable, Sendable { let key: String; let value: Double; let kind: String; let source: String; let note: String? }
struct UpperTarget: Codable, Sendable { let value: Double; let appliesToTotal: Bool; let note: String? }
struct LimitTarget: Codable, Sendable { let key: String; let zh: String; let unit: String; let ideal: Double; let limit: Double; let idealSource: String; let limitSource: String; let note: String? }
struct ProteinTargets: Codable, Sendable { let rdaG: Double; let idealLowG: Double; let idealHighG: Double; let perKgRda: Double }
struct Amdr: Codable, Sendable { let protein: [Double]; let carb: [Double]; let fat: [Double]; let n6: [Double]?; let n3: [Double]? }
struct Targets: Codable, Sendable {
    let date: String; let age: Int; let sex: String; let lifeStage: String; let lifeStageZh: String; let physiology: String; let sensitive: Bool
    let weightKg: Double; let heightCm: Double; let bmi: Double; let bmiCategory: KeyZh; let referenceWeightKg: Double
    let bmr: Double; let eer: Double; let eerMethod: String; let goal: String; let goalDeltaKcal: Double; let energyTarget: Double; let energyFloor: Double
    let protein: ProteinTargets
    let intake: [String: IntakeTarget]; let upper: [String: UpperTarget]; let limits: [String: LimitTarget]
    let amdr: Amdr; let addedSugarPerMealG: Double; let aspartameAdiMg: Double
    static let limitOrder = ["sodium_mg", "added_sugars_g", "sat_fat_pct", "trans_fat_g", "alcohol_g", "caffeine_mg", "upf_pct"]
}

// MARK: - Scoring (rep §3)
struct CompositePart: Codable, Sendable, Hashable { let key: String; let zh: String; let weight: Double; let score: Double?; let points: Double?; let note: String }
struct CompositeScore: Codable, Sendable, Hashable { let score: Double?; let parts: [CompositePart]; let missing: [String] }
struct CategoryResult: Codable, Sendable { let key: String; let zh: String; let score: Double; let source: String; let note: String }
struct ScoreItem: Codable, Sendable, Identifiable {
    let key: String; let category: String; let zh: String; let value: Double; let unit: String; let targetText: String
    let target: Double?; let ideal: Double?; let limit: Double?; let status: ScoreStatus
    let score: Double; let points: Double; let maxPoints: Double; let message: String; let sources: [String]
    var id: String { key }
}
struct HeiComponent: Codable, Sendable, Identifiable { let key: String; let zh: String; let score: Double; let max: Double; let value: Double; let unit: String; let hint: String; let best: Double?; let worst: Double?; var id: String { key } }
struct HeiResult: Codable, Sendable { let total: Double; let components: [HeiComponent] }
struct MarNutrient: Codable, Sendable { let key: String; let zh: String; let intake: Double; let target: Double; let nar: Double }
struct MarResult: Codable, Sendable { let value: Double; let nutrients: [MarNutrient] }
struct HazardResult: Codable, Sendable, Identifiable { let key: String; let zh: String; let iarc: String; let dose: Double; let unit: String; let foods: [String]; let message: String; let sources: [String]; var id: String { key } }
struct EnergyResult: Codable, Sendable {
    let intake: Double; let resting: Double; let restingSource: String; let active: Double; let activeSource: String
    let exerciseKcal: Double; let tef: Double; let tdee: Double; let method: String; let target: Double; let balance: Double
}
struct MacroPct: Codable, Sendable { let protein: Double; let carb: Double; let fat: Double; let satFat: Double; let addedSugar: Double; let alcohol: Double }
struct Completeness: Codable, Sendable { let level: String; let note: String }
struct TopLists: Codable, Sendable { let issues: [String]; let wins: [String] }
struct DailyScore: Codable, Sendable {
    let date: String; let hasData: Bool; let score: Double?; let total: CompositeScore; let categories: [CategoryResult]
    let items: [ScoreItem]; let hei: HeiResult?; let mar: MarResult?; let hazards: [HazardResult]; let energy: EnergyResult
    let totals: Vec; let groups: Vec; let macroPct: MacroPct; let upfPct: Double
    let mealCount: Int; let itemCount: Int; let fastFoodMeals: Int; let completeness: Completeness; let top: TopLists
    let weightKg: Double; let weighedToday: Double?; let version: Int?
    func item(_ key: String) -> ScoreItem? { items.first { $0.key == key } }
}

// MARK: - Indices (rep §5)
struct Le8Component: Codable, Sendable, Identifiable { let key: String; let zh: String; let points: Double?; let value: String; let rule: String; let missing: String; var id: String { key } }
struct Le8Result: Codable, Sendable { let score: Double?; let category: KeyZh?; let available: Int; let components: [Le8Component] }
struct WcrfComponent: Codable, Sendable, Identifiable { let key: String; let zh: String; let points: Double?; let max: Double; let detail: String; let rule: String; var id: String { key } }
struct WcrfResult: Codable, Sendable { let score: Double; let max: Double; let components: [WcrfComponent] }
struct MepaItem: Codable, Sendable, Identifiable { let key: String; let zh: String; let criterion: String; let value: Double; let unit: String; let met: Bool; var id: String { key } }
struct MepaResult: Codable, Sendable { let score: Int; let days: Int; let items: [MepaItem] }
struct PhysicalActivitySummary: Codable, Sendable { let le8MinPerWeek: Double?; let mvpaMinPerWeek: Double?; let strengthDays: Int }
struct HealthIndices: Codable, Sendable {
    let windowDays: Int; let loggedDays: Int; let mepa: MepaResult?; let le8: Le8Result; let wcrf: WcrfResult
    let pa: PhysicalActivitySummary; let sleepHours: Double?
}

// MARK: - Day, meals, raw rows (rep §2, meals §1.9/§1.11, body §2)
struct HazardEntry: Codable, Sendable, Hashable { var key: String; var amount: Double; var note: String? }
struct MealItem: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let meal_id: Int; let name: String; let amount_g: Double; let nutrients: Vec; let groups: Vec
    let hazards: [HazardEntry]; let nova_group: Int?; let category: String?; let amount_desc: String?; let food_id: Int?
    let cooking_method: String?; let confidence: String?; let notes: String?
}
struct Meal: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let time: String; let meal_type: String; let description: String
    let photos: [String]; let ai_summary: String?; let items: [MealItem]
    var isWater: Bool { description == "饮水" }
    var kcal: Double { items.reduce(0) { $0 + $1.nutrients.v("energy_kcal") } }
}
struct ActivityDay: Codable, Sendable, Hashable {
    let date: String; let steps: Double?; let active_kcal: Double?; let resting_kcal: Double?; let distance_km: Double?
    let exercise_min: Double?; let sleep_hours: Double?; let stand_hours: Double?; let source: String; let updated_at: String?
}
struct Exercise: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let time: String; let description: String; let activity_key: String?
    let met: Double; let duration_min: Double; let distance_km: Double?; let kcal: Double; let in_device: Int
    let avg_hr: Double?; let device_kcal: Double?; let source: String; let created_at: String?
    let external_id: String?; let source_name: String?          // present after server migration v3
    var inDevice: Bool { in_device != 0 }
}
struct BodyMetric: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let time: String; let weight_kg: Double?; let body_fat_pct: Double?; let waist_cm: Double?
    let sbp: Double?; let dbp: Double?; let bp_treated: Int; let note: String?; let source: String; let created_at: String?
    let external_id: String?; let source_name: String?
}
struct LabResult: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let date: String; let total_chol: Double?; let hdl: Double?; let non_hdl: Double?; let ldl: Double?
    let lipid_treated: Int; let fasting_glucose: Double?; let hba1c: Double?; let diabetes: Int; let note: String?; let created_at: String?
}
struct DayResponse: Codable, Sendable {
    let date: String; let indices: HealthIndices; let score: DailyScore; let targets: Targets; let meals: [Meal]
    let activity: ActivityDay?; let exercises: [Exercise]; let body: [BodyMetric]; let weightTrend: Double?; let full: Bool
    var visibleMeals: [Meal] { meals.filter { !$0.isWater } }
    var waterMl: Double { meals.first(where: { $0.isWater })?.items.first?.amount_g ?? 0 }
}

// MARK: - Drafts, meal requests, preview (meals §1.8–1.15, §2.1–2.14)
struct HazardPer100: Codable, Sendable, Hashable { var key: String; var amount_per_100g: Double; var note: String? }
struct Per100: Codable, Sendable, Hashable { var nutrients: Vec; var groups: Vec; var hazards: [HazardPer100] }
struct DraftItem: Codable, Sendable, Hashable, Identifiable {
    var localId: UUID = UUID()      // client-only, not encoded
    var name: String; var amount_g: Double; var amount_desc: String?; var food_id: Int?; var category: String?
    var cooking_method: String?; var nova_group: Int?; var confidence: String?
    var nutrients: Vec; var groups: Vec; var hazards: [HazardEntry]; var notes: String?
    var per100: Per100; var save_suggested: Bool; var saved_food_id: Int?
    var id: UUID { localId }
    enum CodingKeys: String, CodingKey {
        case name, amount_g, amount_desc, food_id, category, cooking_method, nova_group, confidence, nutrients, groups, hazards, notes, per100, save_suggested, saved_food_id
    }
}
struct MealDraft: Codable, Sendable { var items: [DraftItem]; var summary: String; var assumptions: [String]; var questions: [String]; var sources: [SourceLink]; var provider: String; var model: String }
struct MealAIRequest: Encodable, Sendable { let text: String; let date: String; let time: String; let meal_type: String; let photos: [String] }
struct MealBody: Encodable, Sendable { let date: String; let time: String; let meal_type: String; let description: String; let photos: [String]; let ai_summary: String; let ai_model: String; let items: [DraftItem] }
struct PreviewMeal: Encodable, Sendable { let meal_type: String; let time: String; let items: [DraftItem]; let replace_meal_id: Int? }
struct PreviewBody: Encodable, Sendable, Hashable { var weight_kg: Double?; var body_fat_pct: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool? }
struct PreviewRequest: Encodable, Sendable { let date: String; var meal: PreviewMeal?; var activity: ActivityValues?; var body: PreviewBody?; var workouts: [WorkoutDraft]? }
struct PreviewIndices: Decodable, Sendable { let before: HealthIndices; let after: HealthIndices }
struct DayPreview: Decodable, Sendable { let date: String; let before: DailyScore; let after: DailyScore; let indices: PreviewIndices }
struct WaterBody: Encodable, Sendable { let ml: Double; let date: String }
struct WaterResponse: Decodable, Sendable { let ok: Bool; let total_ml: Double }
struct RecentItem: Decodable, Sendable, Hashable { let name: String; let food_id: Int?; let amount_g: Double; let n: Int; let last: String }
struct UploadedPhoto: Codable, Sendable, Hashable, Identifiable { let id: String; let url: String }
struct UploadResponse: Decodable, Sendable { let photos: [UploadedPhoto] }
struct AIStatus: Decodable, Sendable { let provider: String; let model: String; let web_search: Bool }

// MARK: - Foods (meals §1.12, §1.14, §2.15–2.21)
enum FoodScope: String, Sendable { case all, mine }
struct Food: Codable, Sendable, Identifiable, Hashable {
    let id: Int; let owner_id: Int; let visibility: String; let name: String; let brand: String?; let aliases: String
    let category: String?; let serving_g: Double?; let serving_desc: String?; let per100: Vec; let groups100: Vec
    let hazards100: [HazardPer100]; let nova_group: Int?; let ingredients: String?; let label_fields: [String]
    let source: String; let source_urls: [SourceLink]; let notes: String?; let use_count: Int
    let created_at: String?; let updated_at: String?; let owner_name: String?; let mine: Bool
}
struct FoodInput: Codable, Sendable, Hashable {
    var name: String; var brand: String; var aliases: [String]; var category: String; var serving_g: Double?; var serving_desc: String
    var per100: Vec; var groups100: Vec; var hazards100: [HazardPer100]; var nova_group: Int?; var ingredients: String
    var label_fields: [String]; var source: String; var source_urls: [SourceLink]; var notes: String; var visibility: String
}
struct FoodDraft: Codable, Sendable {
    let name: String; let brand: String; let aliases: [String]; let category: String; let serving_g: Double; let serving_desc: String
    let per100: Vec; let groups100: Vec; let hazards100: [HazardPer100]; let nova_group: Int?; let ingredients: String
    let label_fields: [String]; let confidence: String; let sources: [SourceLink]; let notes: String; let source: String; let provider: String
}
struct FoodAIRequest: Encodable, Sendable { let name: String; let brand: String; let note: String; let photos: [String] }
struct FoodItemRequest: Encodable, Sendable { let grams: Double? }
struct FromItemRequest: Encodable, Sendable { let item: DraftItem; let name: String; let brand: String; let aliases: [String]; let serving_g: Double; let serving_desc: String; let source_urls: [SourceLink]; let visibility: String }

// MARK: - Body & activity (body §2–§5)
struct BodyInput: Encodable, Sendable { var date: String; var time: String; var weight_kg: Double?; var body_fat_pct: Double?; var waist_cm: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool; var note: String? }
struct LabInput: Encodable, Sendable { var date: String; var total_chol: Double?; var hdl: Double?; var ldl: Double?; var non_hdl: Double?; var fasting_glucose: Double?; var hba1c: Double?; var lipid_treated: Bool; var diabetes: Bool; var note: String? }
struct ActivityValues: Codable, Sendable, Hashable {
    var steps: Double?; var active_kcal: Double?; var resting_kcal: Double?; var distance_km: Double?
    var exercise_min: Double?; var sleep_hours: Double?; var stand_hours: Double?
    init(steps: Double? = nil, active_kcal: Double? = nil, resting_kcal: Double? = nil, distance_km: Double? = nil, exercise_min: Double? = nil, sleep_hours: Double? = nil, stand_hours: Double? = nil) {
        self.steps = steps; self.active_kcal = active_kcal; self.resting_kcal = resting_kcal; self.distance_km = distance_km
        self.exercise_min = exercise_min; self.sleep_hours = sleep_hours; self.stand_hours = stand_hours
    }
    init(_ day: ActivityDay?) {
        self.init(steps: day?.steps, active_kcal: day?.active_kcal, resting_kcal: day?.resting_kcal, distance_km: day?.distance_km,
                  exercise_min: day?.exercise_min, sleep_hours: day?.sleep_hours, stand_hours: day?.stand_hours)
    }
}
struct ActivityList: Decodable, Sendable { let days: [ActivityDay]; let exercises: [Exercise] }
struct ExerciseInput: Encodable, Sendable { var date: String; var time: String?; var activity_key: String?; var met: Double?; var duration_min: Double; var distance_km: Double?; var description: String?; var in_device: Bool; var source: String? }
struct ExerciseCreated: Decodable, Sendable { let id: Int; let kcal: Double }
struct InDeviceBody: Encodable, Sendable { let in_device: Bool }
struct ActivityAIRequest: Encodable, Sendable { let text: String; let date: String; let photos: [String] }
struct BodyDraft: Codable, Sendable, Hashable { var weight_kg: Double?; var body_fat_pct: Double?; var sbp: Double?; var dbp: Double? }
struct WorkoutDraft: Codable, Sendable, Hashable, Identifiable {
    var localId: UUID = UUID()
    var description: String; var activity_key: String; var met: Double; var duration_min: Double; var distance_km: Double?
    var kcal: Double?; var notes: String?; var avg_hr: Double?; var device_kcal: Double?; var in_device: Bool
    var id: UUID { localId }
    enum CodingKeys: String, CodingKey { case description, activity_key, met, duration_min, distance_km, kcal, notes, avg_hr, device_kcal, in_device }
}
struct ActivityDraft: Codable, Sendable {
    var date: String; var date_from_image: Bool; var activity: ActivityValues; var body: BodyDraft; var workouts: [WorkoutDraft]
    var notes: String; var provider: String; var model: String
}
struct CommitBody: Encodable, Sendable { var weight_kg: Double?; var body_fat_pct: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool; var time: String? }
struct ActivityCommitRequest: Encodable, Sendable { let date: String; let source: String; let activity: ActivityValues; let body: CommitBody; let workouts: [WorkoutDraft] }
struct ActivityCommitResponse: Decodable, Sendable { let ok: Bool; let date: String; let workouts: Int }

// MARK: - Period & reports (rep §6–§8)
struct ItemStat: Codable, Sendable, Identifiable { let key: String; let zh: String; let category: String; let good: Int; let ok: Int; let warn: Int; let bad: Int; let days: Int; var id: String { key } }
struct PeriodCheck: Codable, Sendable, Identifiable { let key: String; let zh: String; let value: Double; let unit: String; let targetText: String; let status: ScoreStatus; let score: Double; let message: String; let sources: [String]; var id: String { key } }
struct PeriodHazard: Codable, Sendable, Identifiable { let key: String; let zh: String; let iarc: String; let dose: Double; let unit: String; let days: Int; var id: String { key } }
struct PeriodEnergy: Codable, Sendable {
    let avgIntake: Double?; let avgTdee: Double; let totalBalance: Double; let predictedChangeKg: Double
    let trendStart: Double?; let trendEnd: Double?; let actualChangeKg: Double?; let empiricalTdee: Double?; let ratePerWeek: Double?
}
struct PeriodSeriesPoint: Codable, Sendable { let date: String; let score: Double?; let total: Double?; let intake: Double; let tdee: Double; let weight: Double?; let trend: Double? }
struct WeeklySummary: Codable, Sendable, Hashable { let headline: String; let summary: String; let wins: [String]; let issues: [String]; let actions: [String] }
struct PeriodScore: Codable, Sendable {
    let start: String; let end: String; let days: Int; let daysLogged: Int; let avgHei: Double?; let avgMar: Double?
    let score: Double?; let total: CompositeScore; let category: KeyZh?; let indices: HealthIndices; let hei: HeiResult?
    let avgTotals: Vec; let avgGroups: Vec; let itemStats: [ItemStat]; let checks: [PeriodCheck]; let hazards: [PeriodHazard]
    let energy: PeriodEnergy; let series: [PeriodSeriesPoint]; let aiSummary: WeeklySummary?; let full: Bool
}
struct PeriodSummaryRequest: Encodable, Sendable { let start: String; let end: String }
struct ReportListItem: Decodable, Sendable, Identifiable { let id: Int; let period: String; let start_date: String; let end_date: String; let score: Double?; let ai_summary: WeeklySummary?; let created_at: String }

// MARK: - Trends (rep §10)
struct TrendDay: Codable, Sendable {
    let date: String; let hasData: Bool; let score: Double?; let total: Double?; let categories: [String: Double]; let hazardCount: Int
    let hei: Double?; let mar: Double?; let intake: Double; let tdee: Double; let target: Double; let exerciseKcal: Double; let energyMethod: String
    let weight: Double?; let trend: Double?; let steps: Double?; let activeKcal: Double?; let completeness: String
    let totals: Vec; let groups: Vec; let macroPct: [String: Double]; let upfPct: Double; let statuses: [String: ScoreStatus]
}
struct TrendsResponse: Codable, Sendable { let start: String; let end: String; let days: [TrendDay] }

// MARK: - Standards (rep §9)
struct NutrientDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let en: String; let unit: String; let group: String; let decimals: Int; let dv: Double?; let note: String?; var id: String { key } }
struct FoodGroupDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let unit: String; let note: String; var id: String { key } }
struct HazardDose: Codable, Sendable { let from: String; let unit: String; let key: String? }
struct HazardDef: Codable, Sendable, Identifiable {
    let key: String; let zh: String; let en: String; let iarc: String; let category: String; let risk: String; let detect: String
    let examples: String; let dose: HazardDose; let refAmount: Double; let aiFlag: Bool?; let sources: [String]; let advice: String
    var id: String { key }
}
struct HazardInfoOnly: Codable, Sendable { let zh: String; let iarc: String; let examples: String; let why: String }
struct HeiDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let en: String; let max: Double; let kind: String; let best: Double; let worst: Double; let unit: String; let hint: String; var id: String { key } }
struct ActivityDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let met: Double; let speedKmh: Double?; let code: String?; let intensity: String; var id: String { key } }
struct ActivityLevelDef: Codable, Sendable, Identifiable { let key: String; let zh: String; let pal: Double; let desc: String; var id: String { key } }
struct SourceDef: Codable, Sendable, Identifiable { let id: String; let org: String; let title: String; let year: String; let url: String }
struct LifeStage: Codable, Sendable, Identifiable { let id: String; let zh: String }
struct Meta: Codable, Sendable {
    let version: Int; let nutrients: [NutrientDef]; let foodGroups: [FoodGroupDef]; let hazards: [HazardDef]; let hazardsInfoOnly: [HazardInfoOnly]
    let hei: [HeiDef]; let activities: [ActivityDef]; let activityLevels: [ActivityLevelDef]; let sources: [SourceDef]
    let lifeStages: [LifeStage]; let marNutrients: [String]; let heiUsMean: Double; let conditions: [ConditionDef]
}
struct DriIntakeRow: Codable, Sendable { let kind: String; let values: [Double?] }
struct DriUpperRow: Codable, Sendable { let appliesToTotal: Bool; let note: String?; let values: [Double?] }
struct DriTables: Codable, Sendable { let lifeStages: [LifeStage]; let intake: [String: DriIntakeRow]; let upper: [String: DriUpperRow]; let sodiumCdrr: [Double]; let proteinPerKg: [Double] }

// MARK: - HealthKit sync (DESIGN §C, new endpoints)
struct SyncDay: Codable, Sendable, Hashable {
    let date: String
    var steps: Double?; var active_kcal: Double?; var resting_kcal: Double?; var distance_km: Double?
    var exercise_min: Double?; var stand_hours: Double?; var sleep_hours: Double?
    var clear: [String]?
}
enum SyncSampleType: String, Codable, Sendable { case body_mass, body_fat, waist, blood_pressure }
struct SyncSample: Codable, Sendable, Hashable {
    let uuid: String; let type: SyncSampleType; let date: String; let time: String; var start: String?
    var value: Double?; var sbp: Double?; var dbp: Double?; var bp_treated: Bool?; var source_name: String?
}
struct SyncWorkout: Codable, Sendable, Hashable {
    let uuid: String; let date: String; let time: String; var start: String?; var end: String?; var hk_activity_type: Int?
    let activity_key: String; let description: String; var met: Double?; let duration_min: Double; var distance_km: Double?
    var avg_hr: Double?; var device_kcal: Double?; let in_device: Bool; var source_name: String?
}
struct HealthSyncRequest: Encodable, Sendable {
    let device_id: String; let device_name: String; let timezone: String; let overwrite_manual: Bool
    var days: [SyncDay]?; var samples: [SyncSample]?; var workouts: [SyncWorkout]?; var deleted: [String]?; var cursors: [String: String]?
}
struct SyncRejected: Decodable, Sendable, Hashable { let date: String?; let uuid: String?; let error: String }
struct KeptManual: Decodable, Sendable, Hashable { let date: String; let fields: [String] }
struct PossibleDuplicate: Decodable, Sendable, Hashable { let uuid: String; let exercise_id: Int; let description: String }
struct SyncDaysResult: Decodable, Sendable { let upserted: Int; let unchanged: Int; let kept_manual: [KeptManual]; let rejected: [SyncRejected] }
struct SyncSamplesResult: Decodable, Sendable { let inserted: Int; let updated: Int; let unchanged: Int; let skipped_tombstoned: Int; let rejected: [SyncRejected] }
struct SyncWorkoutsResult: Decodable, Sendable { let inserted: Int; let updated: Int; let unchanged: Int; let skipped_tombstoned: Int; let rejected: [SyncRejected]; let possible_duplicates: [PossibleDuplicate] }
struct SyncDeletedResult: Decodable, Sendable { let body: Int; let exercises: Int; let not_found: Int }
struct HealthSyncResponse: Decodable, Sendable {
    let ok: Bool; let timezone: String; let server_today: String; let timezone_mismatch: Bool
    let days: SyncDaysResult?; let samples: SyncSamplesResult?; let workouts: SyncWorkoutsResult?; let deleted: SyncDeletedResult?
    let invalidated_from: String?
}
struct SyncKindState: Decodable, Sendable { let last_synced_at: String; let min_date: String?; let max_date: String?; let cursor: String? }
struct SyncDeviceState: Decodable, Sendable, Identifiable { let device_id: String; let device_name: String?; let kinds: [String: SyncKindState]; var id: String { device_id } }
struct SyncCounts: Decodable, Sendable { let days: Int; let body: Int; let workouts: Int }
struct LegacySources: Decodable, Sendable { let apple_shortcut_days: Int; let apple_export_days: Int }
struct HealthSyncState: Decodable, Sendable { let timezone: String; let server_today: String; let devices: [SyncDeviceState]; let counts: SyncCounts; let legacy_sources: LegacySources }
struct HealthUnlinkRequest: Encodable, Sendable { let device_id: String; let delete_data: Bool }
struct HealthUnlinkCounts: Decodable, Sendable { let body: Int; let exercises: Int; let days: Int }
struct HealthUnlinkResponse: Decodable, Sendable { let ok: Bool; let deleted: HealthUnlinkCounts }
/// UI-facing status published by HealthSyncService (WP9) and read by Body/More screens.
struct HealthSyncStatus: Sendable, Equatable {
    var isAvailable: Bool = false; var isEnabled: Bool = false; var isSyncing: Bool = false
    var lastSyncAt: Date? = nil; var lastSummary: String? = nil; var lastError: String? = nil
    var keptManualDates: [String] = []; var serverSupportsSync: Bool = true
}
enum HealthSyncReason: String, Sendable { case launch, foreground, observer, backgroundRefresh, manual, settingsChanged }
```

```swift
// Core/Models/Vocab.swift — signatures + enums (WP0-A fills arrays from the cited spec sections)
import Foundation

struct MealTypeDef: Sendable, Hashable { let key: String; let zh: String; let defaultTime: String }
struct LabeledKey: Sendable, Hashable { let key: String; let zh: String }
struct ExtraMetric: Sendable, Hashable { let key: String; let zh: String; let unit: String }

enum Sex: String, CaseIterable, Sendable { case male, female
    var zh: String { self == .male ? "男" : "女" } }
enum ActivityLevel: String, CaseIterable, Sendable { case inactive, low_active, active, very_active
    var zh: String { switch self { case .inactive: "久坐"; case .low_active: "轻度活动"; case .active: "活跃"; case .very_active: "非常活跃" } } }
enum Goal: String, CaseIterable, Sendable { case lose, maintain, gain
    var zh: String { switch self { case .lose: "减重"; case .maintain: "维持"; case .gain: "增重" } } }
enum Physiology: String, CaseIterable, Sendable { case none, pregnant, lactating
    var zh: String { switch self { case .none: "无"; case .pregnant: "孕期"; case .lactating: "哺乳期" } } }
enum SodiumMode: String, CaseIterable, Sendable { case cdrr, aha
    var zh: String { self == .cdrr ? "2300 mg（DGA/NASEM）" : "1500 mg（AHA 理想）" } }
enum Nicotine: String, CaseIterable, Sendable { case unknown, never, former_5y, former_1_5y, former_lt1y, ecig, current
    var zh: String { switch self { case .unknown: "不填写（LE8 不计这一项）"; case .never: "从不吸烟"; case .former_5y: "已戒烟 5 年以上"; case .former_1_5y: "已戒烟 1–5 年"; case .former_lt1y: "戒烟不到 1 年"; case .ecig: "使用电子烟"; case .current: "目前吸烟" } } }
enum ShareMode: String, CaseIterable, Sendable { case `private`, `public`, selected
    var zh: String { switch self { case .private: "仅自己"; case .public: "所有成员"; case .selected: "指定成员" } } }
enum ShareDetail: String, CaseIterable, Sendable { case summary, full
    var zh: String { self == .summary ? "仅评分与趋势" : "完整记录（含吃了什么）" } }

enum Vocab {
    static let nutrientOrder: [String] = []            // 43 keys, meals §1.1 order
    static let foodGroupOrder: [String] = []           // 22 keys, meals §1.2 order
    static let itemEditorMainNutrients: [String] = []  // 13 keys, meals §1.1
    static let foodEditorMainNutrients: [String] = []  // 10 keys, meals §1.1
    static let nutrientGroupZh: [String: String] = [:] // rep §9.1
    static let mealTypes: [MealTypeDef] = []           // meals §1.6
    static let categories: [LabeledKey] = []           // meals §1.3 (picker order)
    static let novaZh: [Int: String] = [:]             // meals §1.4
    static let foodSourceZh: [String: String] = [:]    // meals §1.12
    static let flagHazardKeys: [String] = []           // 12 keys with dose.from == "flag"
    static let activeSourceZh: [String: String] = [:]  // web1 §4.3 A2
    static let intakeOrder: [String] = []              // rep §9.4 (31)
    static let upperOrder: [String] = []               // rep §9.4 (17)
    static let marNutrients: [String] = []             // rep §3.6 (11)
    static let timezones: [String] = []                // auth §5 (11)
    static let avatarColors: [String] = []             // auth §3.2 (8)
    static let goalRates: [Double] = [0.25, 0.5, 0.75, 1]
    static let trendsExtraMetrics: [ExtraMetric] = []  // rep §10.3 / web2 §5.1.5(4)
    static func mealZh(_ key: String) -> String { mealTypes.first { $0.key == key }?.zh ?? key }
    static func categoryZh(_ key: String?) -> String? { guard let key else { return nil }; return categories.first { $0.key == key }?.zh ?? key }
    static func guessMealType(hour: Int) -> String { hour < 10 ? "breakfast" : hour < 14 ? "lunch" : hour < 17 ? "snack" : hour < 21 ? "dinner" : "snack" }
    static func bodySourceLabel(_ source: String) -> String { switch source { case "manual": ""; case "profile": "建档"; case "ai": "AI 识别"; default: "Apple 健康" } }
    static func activitySourceLabel(_ source: String) -> String { switch source { case "manual": "手动"; case "apple_shortcut": "iPhone 快捷指令"; case "ai_screenshot": "AI 识别"; case "healthkit": "Apple 健康"; default: "“健康”App 导出" } }
    static func iarcLabel(_ group: String) -> String { group == "—" ? "非致癌" : "IARC \(group) 类" }
}
```

#### E.3.2 Utilities, errors, networking primitives, auth storage
WP0-A owns the `Core/Util/*` parts (`fmt`, `Fmt`, `LocalDay`, `Timestamps`, `ItemMath`, `Debouncer`, `DiskCache`, `UncheckedSendable`). WP0-B owns the rest of this listing.
```swift
import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors
enum APIError: Error, LocalizedError, Sendable, Equatable {
    case http(status: Int, message: String)
    case unauthorized(message: String)
    case network(message: String)
    case decoding(message: String)
    case jobFailed(message: String)
    case unsupportedByServer
    var message: String {
        switch self {
        case .http(_, let m), .unauthorized(let m), .network(let m), .jobFailed(let m): return m
        case .decoding(let m): return "数据解析失败：\(m)"
        case .unsupportedByServer: return "服务器版本过旧，暂不支持此功能"
        }
    }
    var status: Int? { if case .http(let s, _) = self { return s }; if case .unauthorized = self { return 401 }; return nil }
    var errorDescription: String? { message }
    static func from(_ error: Error) -> APIError {
        if let e = error as? APIError { return e }
        return .network(message: error.localizedDescription)
    }
}
struct APIErrorBody: Decodable, Sendable { let error: String }

enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

struct AnyEncodable: Encodable, Sendable {
    private let encodeFn: @Sendable (Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ value: T) { encodeFn = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

struct MultipartFile: Sendable { let fieldName: String; let filename: String; let mimeType: String; let data: Data }
struct MultipartFormData: Sendable {
    let boundary: String
    init(boundary: String = "NutriLog-\(UUID().uuidString)") { self.boundary = boundary }
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    func body(files: [MultipartFile], fields: [String: String] = [:]) -> Data { Data() }
}

// MARK: - APIClient
actor APIClient {
    nonisolated let session: URLSession
    private(set) var baseURL: URL
    private var token: String?
    private var unauthorizedHandler: (@Sendable () async -> Void)?
    init(baseURL: URL, token: String?) {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieAcceptPolicy = .never; cfg.httpShouldSetCookies = false; cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
        self.baseURL = baseURL; self.token = token
    }
    func setToken(_ token: String?) { self.token = token }
    func setBaseURL(_ url: URL) { baseURL = url }
    func setUnauthorizedHandler(_ handler: @escaping @Sendable () async -> Void) { unauthorizedHandler = handler }
    func currentToken() -> String? { token }

    /// Core request. `path` is relative to /api/v1 without leading slash, e.g. "day/2026-10-03".
    func send<R: Decodable & Sendable>(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: AnyEncodable? = nil, as type: R.Type = R.self) async throws -> R { fatalError() }
    func sendNoContent(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: AnyEncodable? = nil) async throws { }
    func upload<R: Decodable & Sendable>(_ path: String, form: MultipartFormData, files: [MultipartFile], fields: [String: String] = [:], as type: R.Type = R.self) async throws -> R { fatalError() }
    func rawData(absolutePath: String) async throws -> Data { Data() }

    // Auth & account (auth §3)
    func health() async throws -> HealthPing { try await send(.get, "health") }
    func authConfig() async throws -> AuthConfig { try await send(.get, "auth/config") }
    func login(username: String, password: String, deviceName: String) async throws -> TokenResponse { fatalError() }
    func register(_ body: RegisterBody) async throws -> TokenResponse { fatalError() }
    func logout() async {}
    func me() async throws -> Me { try await send(.get, "auth/me") }
    func sessions() async throws -> [SessionRow] { fatalError() }
    func deleteSession(id: Int) async throws {}
    func changePassword(old: String, new: String) async throws {}
    func saveProfile(_ profile: Profile) async throws -> Profile { fatalError() }
    func targets(date: String?) async throws -> Targets { fatalError() }
    func saveSettings(_ body: SettingsBody) async throws {}
    func regeneratePersonalToken() async throws -> String { fatalError() }
    func refreshToken() async throws -> TokenResponse { fatalError() }
    func deleteAccount(password: String) async throws {}
    func users() async throws -> [CommunityUser] { fatalError() }
    // Body & activity (body §3–§5)
    func bodyMetrics(start: String?, end: String?) async throws -> [BodyMetric] { fatalError() }
    func addBodyMetric(_ body: BodyInput) async throws -> Int { fatalError() }
    func deleteBodyMetric(id: Int) async throws {}
    func labs() async throws -> [LabResult] { fatalError() }
    func addLab(_ lab: LabInput) async throws -> Int { fatalError() }
    func deleteLab(id: Int) async throws {}
    func activity(start: String?, end: String?) async throws -> ActivityList { fatalError() }
    func putActivity(date: String, _ values: ActivityValues) async throws {}
    func addExercise(_ input: ExerciseInput) async throws -> ExerciseCreated { fatalError() }
    func setExerciseInDevice(id: Int, inDevice: Bool) async throws {}
    func deleteExercise(id: Int) async throws {}
    func startActivityAI(_ req: ActivityAIRequest) async throws -> String { fatalError() }
    func preview(_ req: PreviewRequest) async throws -> DayPreview { fatalError() }
    func commitActivity(_ req: ActivityCommitRequest) async throws -> ActivityCommitResponse { fatalError() }
    func healthSync(_ req: HealthSyncRequest) async throws -> HealthSyncResponse { fatalError() }
    func healthSyncState() async throws -> HealthSyncState { fatalError() }
    func healthSyncUnlink(_ req: HealthUnlinkRequest) async throws -> HealthUnlinkResponse { fatalError() }
    // Log, AI, foods (meals §2)
    func uploadPhotos(jpegs: [Data]) async throws -> [UploadedPhoto] { fatalError() }
    func photoData(id: String) async throws -> Data { fatalError() }
    func aiStatus() async throws -> AIStatus { fatalError() }
    func startMealAI(_ req: MealAIRequest) async throws -> String { fatalError() }
    func startFoodAI(_ req: FoodAIRequest) async throws -> String { fatalError() }
    func job<T: Decodable & Sendable>(id: String, as type: T.Type) async throws -> Job<T> { fatalError() }
    func createMeal(_ body: MealBody) async throws -> Int { fatalError() }
    func updateMeal(id: Int, _ body: MealBody) async throws {}
    func deleteMeal(id: Int) async throws {}
    func recentItems() async throws -> [RecentItem] { fatalError() }
    func addWater(ml: Double, date: String) async throws -> Double { fatalError() }
    func foods(query: String?, scope: FoodScope) async throws -> [Food] { fatalError() }
    func food(id: Int) async throws -> Food { fatalError() }
    func createFood(_ input: FoodInput) async throws -> Int { fatalError() }
    func updateFood(id: Int, _ input: FoodInput) async throws {}
    func deleteFood(id: Int) async throws {}
    func foodItem(id: Int, grams: Double?) async throws -> DraftItem { fatalError() }
    func saveFoodFromItem(_ req: FromItemRequest) async throws -> Int { fatalError() }
    // Reports & standards (rep §2–§11)
    func day(_ date: String, user: String?) async throws -> DayResponse { fatalError() }
    func trends(start: String, end: String, user: String?) async throws -> TrendsResponse { fatalError() }
    func period(start: String, end: String, user: String?) async throws -> PeriodScore { fatalError() }
    func startPeriodSummary(start: String, end: String) async throws -> String { fatalError() }
    func reports() async throws -> [ReportListItem] { fatalError() }
    func standardsMeta() async throws -> Meta { fatalError() }
    func standardsDri() async throws -> DriTables { fatalError() }
}

// MARK: - Jobs
enum JobPhase: Sendable, Equatable { case queued, running }
struct JobPoller: Sendable {
    let api: APIClient
    var interval: Duration = .milliseconds(1500)
    /// Polls until done. Returns `result` (may be nil for summary jobs). Throws APIError.jobFailed / CancellationError.
    func wait<T: Decodable & Sendable>(jobId: String, as type: T.Type, onPhase: @escaping @MainActor @Sendable (JobPhase) -> Void = { _ in }) async throws -> T? {
        while true {
            try Task.checkCancellation()
            let j = try await api.job(id: jobId, as: T.self)
            switch j.status {
            case .done: return j.result
            case .error: throw APIError.jobFailed(message: j.error ?? "AI 任务失败")
            case .queued: await onPhase(.queued)
            case .running: await onPhase(.running)
            }
            try await Task.sleep(for: interval)
        }
    }
}
struct PendingJob: Codable, Sendable, Identifiable, Hashable { let id: String; let kind: String; let createdAt: Date; let context: [String: String] }
enum PendingJobStore {
    static func save(_ job: PendingJob) {}
    static func remove(id: String) {}
    static func all(kind: String) -> [PendingJob] { [] }
}

// MARK: - Images
enum ImageTranscoder {
    /// Any ImageIO-readable image (HEIC/PNG/JPEG…) → JPEG, long edge ≤ maxPixel, EXIF orientation applied.
    static func jpeg(from data: Data, maxPixel: Int = 2048, quality: Double = 0.8) -> Data? { nil }
    static func jpeg(from image: UIImage, maxPixel: Int = 2048, quality: Double = 0.8) -> Data? { nil }
}
actor PhotoCache {
    static let shared = PhotoCache()
    func data(for photoId: String, api: APIClient) async throws -> Data { Data() }
    func clear() {}
}

// MARK: - Auth storage
struct StoredToken: Codable, Sendable, Equatable { let token: String; let expires_at: String }
enum KeychainStore {
    static func save(_ data: Data, account: String) -> Bool { true }
    static func load(account: String) -> Data? { nil }
    static func delete(account: String) {}
}
enum TokenStore {
    static func load() -> StoredToken? { nil }
    static func save(_ token: StoredToken) {}
    static func clear() {}
}
enum DeviceInfo {
    static var deviceName: String { "iPhone · 食迹" }
    static var installId: String { "id" }
}
enum ServerConfig {
    static let defaultURL = URL(string: "http://45.63.23.52:8787")!
    static var current: URL { defaultURL }
    static func save(_ url: URL) {}
    static func normalize(_ text: String) -> URL? { nil }
}
enum DiskCache {
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? { nil }
    static func save<T: Encodable>(_ value: T, key: String) {}
    static func removeAll() {}
}

// MARK: - Util
func fmt(_ v: Double?, _ d: Int = 0) -> String {
    guard let v, v.isFinite else { return "—" }
    return v.formatted(.number.precision(.fractionLength(0...d)).locale(Locale(identifier: "zh_CN")).rounded(rule: .toNearestOrAwayFromZero))
}
enum Fmt {
    static func signed(_ v: Double?, _ d: Int = 0) -> String { guard let v else { return "—" }; return (v > 0 ? "+" : "") + fmt(v, d) }
    static func compact(_ v: Double?) -> String { guard let v else { return "—" }; return abs(v) >= 10000 ? fmt(v / 10000, 1) + "万" : fmt(v) }
    static func kcal(_ v: Double?) -> String { "\(fmt(v)) kcal" }
}
enum LocalDay {
    static func addDays(_ date: String, _ n: Int) -> String { date }
    static func diffDays(_ a: String, _ b: String) -> Int { 0 }
    static func weekStart(_ date: String) -> String { date }
    static func monthStart(_ date: String) -> String { String(date.prefix(8)) + "01" }
    static func monthEnd(_ date: String) -> String { date }
    static func addMonths(_ date: String, _ n: Int) -> String { date }
    static func range(_ start: String, _ end: String) -> [String] { [] }
    static func shortDate(_ date: String) -> String { date }
    static func dateLabel(_ date: String, today: String) -> String { date }
    static func isValid(_ date: String) -> Bool { true }
    static func key(for date: Date, in timeZone: TimeZone) -> String { "" }
    static func date(fromKey key: String, in timeZone: TimeZone) -> Date? { nil }
    static func deviceToday() -> String { "" }
    static func nowHHMM(in timeZone: TimeZone = .current) -> String { "" }
    static func hhmm(_ date: Date, in timeZone: TimeZone) -> String { "" }
}
enum Timestamps {
    static func iso(_ s: String?) -> Date? { nil }
    static func sqlite(_ s: String?) -> Date? { nil }
}
enum ItemMath {
    static func rescale(_ item: DraftItem, grams: Double) -> DraftItem { item }
    static func toDraft(_ item: MealItem) -> DraftItem { fatalError() }
    static func setNutrient(_ item: DraftItem, key: String, value: Double) -> DraftItem { item }
    static func setGroup(_ item: DraftItem, key: String, value: Double) -> DraftItem { item }
    static func addHazard(_ item: DraftItem, key: String) -> DraftItem { item }
    static func removeHazard(_ item: DraftItem, at index: Int) -> DraftItem { item }
    static func totals(_ items: [DraftItem]) -> Vec { [:] }
    static func netKcal(met: Double, weightKg: Double, minutes: Double) -> Double { max(0, (met - 1) * weightKg * minutes / 60) }
}
@MainActor final class Debouncer {
    private var task: Task<Void, Never>?
    let delay: Duration
    init(_ delay: Duration) { self.delay = delay }
    func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }
    func cancel() { task?.cancel() }
}

// Core/Util/UncheckedSendable.swift (WP0-A)
struct UncheckedSendable<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }
```

**Endpoint mapping for `APIClient`** (WP0-B). Every method follows the spec section; the request or response type is the model listed.

| Method | HTTP | Notes |
|---|---|---|
| `health()` | GET `health` | |
| `authConfig()` | GET `auth/config` | §C.6. A 404 becomes `.unsupportedByServer`, which the caller handles. |
| `login(username:password:deviceName:)` | POST `auth/token` `LoginBody` → `TokenResponse` | Trim username and password |
| `register(_:)` | POST `auth/register` `RegisterBody` → `TokenResponse` (`user` nil) | Always a non-empty `device_name` |
| `logout()` | POST `auth/logout` `{}` | Swallows every error |
| `me()` | GET `auth/me` → `Me` | |
| `sessions()` / `deleteSession(id:)` | GET `auth/sessions` / DELETE `auth/sessions/{id}` | |
| `changePassword(old:new:)` | POST `auth/password` `PasswordBody` | `old` trimmed |
| `saveProfile(_:)` | PUT `profile` `Profile` → `ProfileSaveResponse.profile` | Full object |
| `targets(date:)` | GET `profile/targets?date=` | |
| `saveSettings(_:)` | PUT `settings` `SettingsBody` | All 5 fields |
| `regeneratePersonalToken()` | POST `settings/token` `{}` → `.token` | |
| `refreshToken()` | POST `auth/refresh` `{}` → `TokenResponse` | §C.8 |
| `deleteAccount(password:)` | POST `account/delete` `DeleteAccountBody` | §C.5 |
| `users()` | GET `users` → `[CommunityUser]` | |
| `bodyMetrics(start:end:)` | GET `body?start&end` | |
| `addBodyMetric(_:)` → id | POST `body` | |
| `deleteBodyMetric(id:)` | DELETE `body/{id}` | |
| `labs()` / `addLab(_:)` / `deleteLab(id:)` | GET/POST `labs`, DELETE `labs/{id}` | mg/dL only |
| `activity(start:end:)` | GET `activity` → `ActivityList` | |
| `putActivity(date:_:)` | PUT `activity/{date}` `ActivityValues` | nil = clear |
| `addExercise(_:)` | POST `exercises` → `ExerciseCreated` | |
| `setExerciseInDevice(id:inDevice:)` | PATCH `exercises/{id}` `InDeviceBody` | |
| `deleteExercise(id:)` | DELETE `exercises/{id}` | |
| `startActivityAI(_:)` → job id | POST `ai/activity` | |
| `preview(_:)` | POST `preview` `PreviewRequest` → `DayPreview` | |
| `commitActivity(_:)` | POST `activity/commit` | |
| `healthSync(_:)` / `healthSyncState()` / `healthSyncUnlink(_:)` | POST `health/sync`, GET `health/sync/state`, POST `health/sync/unlink` | §C.2–§C.4; 120 s timeout |
| `uploadPhotos(jpegs:)` | POST `uploads` multipart `photos` → `[UploadedPhoto]` | ≤6; filenames `photo{n}.jpg` |
| `photoData(id:)` | GET `uploads/{id}` → raw `Data` | |
| `aiStatus()` | GET `ai/status` | |
| `startMealAI(_:)` / `startFoodAI(_:)` → job id | POST `ai/meal` / `ai/food` | |
| `job(id:as:)` | GET `ai/jobs/{id}` → `Job<T>` | |
| `createMeal(_:)` → id / `updateMeal(id:_:)` / `deleteMeal(id:)` | POST `meals` / PUT `meals/{id}` / DELETE `meals/{id}` | |
| `recentItems()` | GET `meals/recent-items` | Filter out `饮用水` |
| `addWater(ml:date:)` → `total_ml` | POST `water` `WaterBody` | |
| `foods(query:scope:)` | GET `foods?q&scope` | Omit `q` when empty |
| `food(id:)` / `createFood` / `updateFood` / `deleteFood` | GET/POST/PUT/DELETE `foods[/{id}]` | |
| `foodItem(id:grams:)` | POST `foods/{id}/item` `FoodItemRequest` → `DraftItem` | |
| `saveFoodFromItem(_:)` → id | POST `foods/from-item` | |
| `day(_:user:)` | GET `day/{date}?user=` | |
| `trends(start:end:user:)` | GET `trends` | 120 s timeout |
| `period(start:end:user:)` | GET `period` | |
| `startPeriodSummary(start:end:)` → job id | POST `period/summary` `PeriodSummaryRequest` | |
| `reports()` | GET `reports` | |
| `standardsMeta()` / `standardsDri()` | GET `standards/meta`, `standards/dri` | |

#### E.3.3 App state, router, health service façade, screen entry points (WP0-B; stubs owned per §B.1)
The listing below is shown as one file; split it into the files named in §B.1:
- `App/AppRouter.swift`: `StandardsTab`, `Route`, `RecognizerMode`, `LogMealRequest`, `AppRouter`.
- `ToastCenter` → `DesignSystem/Components/Toast.swift` (WP0-C).
- `AppState`, `RootView`, `MainTabView` (+ `RouteDestinationView`), `AppDelegate` and `NutriLogApp` each go to their `App/` file.
- Each stub goes to its feature path from §E.3.6.
- `HealthSyncService` → `Core/Health/HealthSyncService.swift`.
```swift
import SwiftUI
import Observation

enum StandardsTab: String, CaseIterable, Hashable, Sendable {
    case mine, dri, hazards, hei, met, rules, sources
    var title: String {
        switch self { case .mine: "我的个性化目标"; case .dri: "DRI 总表"; case .hazards: "致癌物与风险物"; case .hei: "HEI-2020"; case .met: "运动 MET"; case .rules: "评分规则"; case .sources: "资料来源" }
    }
}
enum Route: Hashable, Sendable {
    case memberDay(username: String)
    case memberTrends(username: String)
    case reports
    case community
    case foods
    case standards(StandardsTab)
    case healthSync
    case shareSettings
}
enum RecognizerMode: String, Sendable { case manual, ai }
struct LogMealRequest: Identifiable, Hashable, Sendable { let id = UUID(); let date: String?; let editMealId: Int? }

@MainActor @Observable final class AppRouter {
    enum Tab: Hashable, Sendable { case today, trends, log, body, more }
    var selectedTab: Tab = .today
    var todayPath = NavigationPath()
    var trendsPath = NavigationPath()
    var bodyPath = NavigationPath()
    var morePath = NavigationPath()
    var logMeal: LogMealRequest?
    var todayFocusDate: String?
    var bodyFocusDate: String?
    func openLogMeal(date: String? = nil, editMealId: Int? = nil) { logMeal = LogMealRequest(date: date, editMealId: editMealId) }
    func push(_ route: Route) {}
    func showToday(date: String?) { selectedTab = .today; todayFocusDate = date }
    func showBody(date: String?) { selectedTab = .body; bodyFocusDate = date }
    func reset() {}
}

@MainActor @Observable final class ToastCenter {
    struct Toast: Identifiable, Equatable { let id = UUID(); let text: String; let isError: Bool }
    private(set) var current: Toast?
    func show(_ text: String) {}
    func error(_ text: String) {}
    func error(_ error: Error) {}
}

@MainActor @Observable final class AppState {
    enum Phase: Equatable { case launching, unreachable(String), loggedOut, onboarding, ready }
    private(set) var phase: Phase = .launching
    private(set) var me: Me?
    private(set) var meta: Meta?
    private(set) var authConfig: AuthConfig?
    private(set) var dataVersion: Int = 0
    var themePreference: ThemePreference = .system
    let api: APIClient
    let toasts = ToastCenter()
    let router = AppRouter()
    let healthSync: HealthSyncService
    var today: String { me?.today ?? LocalDay.deviceToday() }
    var profile: Profile? { me?.profile }
    var user: User? { me?.user }
    var isMockAI: Bool { me?.ai.isMock ?? true }
    var profileTimeZone: TimeZone { TimeZone(identifier: me?.profile?.timezone ?? "Asia/Shanghai") ?? .current }
    var serverURL: URL { ServerConfig.current }
    init() {
        api = APIClient(baseURL: ServerConfig.current, token: TokenStore.load()?.token)
        healthSync = HealthSyncService(api: api)
        healthSync.attach(to: self)
    }
    func bootstrap() async {}
    func login(username: String, password: String) async throws {}
    func register(username: String, password: String, displayName: String, inviteCode: String) async throws {}
    func refreshMe() async {}
    func logout() async {}
    func handleUnauthorized() async {}
    func noteDataChanged() { dataVersion += 1 }
    func onForeground() async {}
    func ensureMeta(force: Bool = false) async {}
    func loadAuthConfig() async {}
    func setServerURL(_ url: URL) async {}
    func didSaveProfile(_ profile: Profile) async {}
    func deleteAccount(password: String) async throws {}
    func nutrientDef(_ key: String) -> NutrientDef? { meta?.nutrients.first { $0.key == key } }
    func hazardDef(_ key: String) -> HazardDef? { meta?.hazards.first { $0.key == key } }
    func source(_ id: String) -> SourceDef? { meta?.sources.first { $0.id == id } }
    func activityDef(_ key: String) -> ActivityDef? { meta?.activities.first { $0.key == key } }
}

// WP9-owned (seeded by WP0 as a stub with exactly this API)
@MainActor @Observable final class HealthSyncService {
    static weak var current: HealthSyncService?
    private(set) var status = HealthSyncStatus()
    let api: APIClient
    private weak var app: AppState?
    init(api: APIClient) { self.api = api; HealthSyncService.current = self }
    func attach(to app: AppState) { self.app = app }
    nonisolated static func registerBackgroundTasks() {}
    static func startObserversIfEnabled() {}
    func onSessionReady() async {}
    func onForeground() async {}
    func onLogout() async {}
    func syncNow(reason: HealthSyncReason) async {}
}

// Screen entry points (WP0 seeds stubs; owning WP replaces bodies, keeps signatures)
struct LoginScreen: View { init() {}; var body: some View { Text("登录") } }
struct OnboardingScreen: View { init() {}; var body: some View { Text("建档") } }
struct MoreScreen: View { init() {}; var body: some View { Text("更多") } }
struct ShareSettingsScreen: View { init() {}; var body: some View { Text("资料与分享") } }
struct TodayScreen: View { let member: String?; init(member: String? = nil) { self.member = member }; var body: some View { Text("今日") } }
struct LogMealScreen: View { let request: LogMealRequest; init(request: LogMealRequest) { self.request = request }; var body: some View { Text("记一餐") } }
struct BodyScreen: View { init() {}; var body: some View { Text("身体") } }
struct ActivityRecognizerSheet: View {
    let date: String; let current: ActivityDay?; let mode: RecognizerMode; let onDone: @MainActor () -> Void
    init(date: String, current: ActivityDay?, mode: RecognizerMode, onDone: @escaping @MainActor () -> Void) { self.date = date; self.current = current; self.mode = mode; self.onDone = onDone }
    var body: some View { Text("活动") }
}
struct TrendsScreen: View { let member: String?; init(member: String? = nil) { self.member = member }; var body: some View { Text("趋势") } }
struct ReportsScreen: View { init() {}; var body: some View { Text("报告") } }
struct CommunityScreen: View { init() {}; var body: some View { Text("社区") } }
struct FoodsScreen: View { init() {}; var body: some View { Text("食物库") } }
struct StandardsScreen: View { let initialTab: StandardsTab; init(initialTab: StandardsTab = .mine) { self.initialTab = initialTab }; var body: some View { Text("标准库") } }
struct HealthSyncScreen: View { init() {}; var body: some View { Text("苹果健康同步") } }
struct ProfilePrefill: Sendable, Equatable { var sex: String?; var birth_date: String?; var height_cm: Double?; var weight_kg: Double? }
struct HealthPrefillButton: View { let onPrefill: @MainActor (ProfilePrefill) -> Void; init(onPrefill: @escaping @MainActor (ProfilePrefill) -> Void) { self.onPrefill = onPrefill }; var body: some View { Text("从苹果健康读取") } }

struct RouteDestinationView: View {
    let route: Route
    var body: some View {
        switch route {
        case .memberDay(let u): TodayScreen(member: u)
        case .memberTrends(let u): TrendsScreen(member: u)
        case .reports: ReportsScreen()
        case .community: CommunityScreen()
        case .foods: FoodsScreen()
        case .standards(let t): StandardsScreen(initialTab: t)
        case .healthSync: HealthSyncScreen()
        case .shareSettings: ShareSettingsScreen()
        }
    }
}
extension View { func nlRouteDestinations() -> some View { navigationDestination(for: Route.self) { RouteDestinationView(route: $0) } } }

struct MainTabView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var router = app.router
        TabView(selection: Binding(get: { router.selectedTab }, set: { t in if t == .log { router.openLogMeal() } else { router.selectedTab = t } })) {
            NavigationStack(path: $router.todayPath) { TodayScreen().nlRouteDestinations() }
                .tabItem { Label("今日", systemImage: "house") }.tag(AppRouter.Tab.today)
            NavigationStack(path: $router.trendsPath) { TrendsScreen().nlRouteDestinations() }
                .tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }.tag(AppRouter.Tab.trends)
            Color.clear.tabItem { Label("记一餐", systemImage: "plus.circle.fill") }.tag(AppRouter.Tab.log)
            NavigationStack(path: $router.bodyPath) { BodyScreen().nlRouteDestinations() }
                .tabItem { Label("身体", systemImage: "scalemass") }.tag(AppRouter.Tab.body)
            NavigationStack(path: $router.morePath) { MoreScreen().nlRouteDestinations() }
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }.tag(AppRouter.Tab.more)
        }
        .sheet(item: $router.logMeal) { req in LogMealScreen(request: req) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        HealthSyncService.registerBackgroundTasks()
        HealthSyncService.startObserversIfEnabled()
        return true
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Group {
            switch app.phase {
            case .launching: LoadingView()
            case .unreachable(let msg): VStack { Text(msg); Button("重试") { Task { await app.bootstrap() } } }
            case .loggedOut: LoginScreen()
            case .onboarding: OnboardingScreen()
            case .ready: MainTabView()
            }
        }
        .toastOverlay(app.toasts)
        .preferredColorScheme(app.themePreference.colorScheme)
    }
}

@main struct NutriLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
                .task { await app.bootstrap() }
                .onChange(of: scenePhase) { _, p in if p == .active { Task { await app.onForeground() } } }
        }
    }
}
```
`AppState` semantics are defined in §B.3. Feature code uses only:
- `app.api`, `app.toasts`, `app.router`, `app.healthSync`
- `app.me`, `app.meta`, `app.today`, `app.profile`, `app.user`, `app.isMockAI`, `app.profileTimeZone`, `app.dataVersion`
- `app.noteDataChanged()`, `app.refreshMe()`, `app.didSaveProfile(_:)`, `app.logout()`, `app.deleteAccount(password:)`, `app.setServerURL(_:)`, `app.ensureMeta()`
- the lookup helpers

#### E.3.4 Design system component APIs (WP0-C; `DesignSystem/Media` is WP0-B)
```swift
import SwiftUI
import PhotosUI
import Charts

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
    static let page = dyn(0xf6f5f1, 0x0f0f0e)
    static let accent = dyn(0x1f6f50, 0x3a9c73)
}
extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) { self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha) }
}
extension Color { init(hex: String) { self = .gray } }

enum ThemePreference: String, CaseIterable, Sendable { case system, light, dark
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
}
extension ScoreStatus {
    var label: String { switch self { case .good, .ok: "达标"; case .warn: "偏离"; case .bad: "不达标"; case .info: "提示" } }
    var symbol: String { switch self { case .good, .ok: "checkmark.circle"; case .warn: "exclamationmark.triangle"; case .bad: "xmark.circle"; case .info: "info.circle" } }
    var fill: Color { .green }
    var text: Color { .green }
    var soft: Color { .green }
}

struct Card<Content: View>: View { let padding: CGFloat; let content: Content
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) { self.padding = padding; self.content = content() }
    var body: some View { content.padding(padding) } }
struct CardHeader<Trailing: View>: View { let title: String; let icon: String?; let hint: String?; let trailing: Trailing
    init(_ title: String, icon: String? = nil, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.icon = icon; self.hint = hint; self.trailing = trailing() }
    var body: some View { HStack { Text(title); trailing } } }
extension CardHeader where Trailing == EmptyView { init(_ title: String, icon: String? = nil, hint: String? = nil) { self.init(title, icon: icon, hint: hint) { EmptyView() } } }
struct StatusBadge: View { let status: ScoreStatus; init(_ status: ScoreStatus) { self.status = status }; var body: some View { Text(status.label) } }
struct MeterMark: Hashable, Sendable { enum Kind: Sendable { case ideal, limit }; let at: Double; let label: String; let kind: Kind }
struct MeterFootLink { let title: String; let action: @MainActor () -> Void }
struct Meter: View {
    init(name: String, value: Double, unit: String, max: Double, marks: [MeterMark] = [], status: ScoreStatus, decimals: Int = 0, foot: String? = nil, footLink: MeterFootLink? = nil) {}
    var body: some View { EmptyView() } }
struct ScoreRing: View { init(score: Double?, grade: String? = nil, size: CGFloat = 148) {}; static func color(for score: Double?) -> Color { .gray }; var body: some View { EmptyView() } }
struct StatTile: View { init(label: String, value: String, unit: String? = nil, delta: String? = nil) {}; var body: some View { EmptyView() } }
struct Chip: View { enum Style: Equatable { case plain, accent, selected, iarc(String) }
    init(_ text: String, icon: String? = nil, style: Style = .plain) {}; var body: some View { EmptyView() } }
struct IarcChip: View { init(_ group: String) {}; var body: some View { EmptyView() } }
struct Banner: View { enum Style { case plain, warn, accent }
    init(_ text: String, icon: String? = nil, style: Style = .plain) {}; var body: some View { EmptyView() } }
struct SegOption<T: Hashable>: Hashable { let value: T; let label: String; var icon: String? = nil }
struct Seg<T: Hashable>: View { init(_ options: [SegOption<T>], selection: Binding<T>) {}; var body: some View { EmptyView() } }
struct DateNav: View { init(date: Binding<String>, today: String) {}; var body: some View { EmptyView() } }
struct Avatar: View { init(name: String, color: String, size: CGFloat = 32) {}; var body: some View { EmptyView() } }
struct EmptyState: View { init(_ text: String, icon: String = "tray") {}; var body: some View { EmptyView() } }
struct LoadingView: View { init() {}; var body: some View { ProgressView("加载中…") } }
struct SourceLinks: View { init(ids: [String], sources: [SourceDef]) {}; var body: some View { EmptyView() } }
struct NumberField: View { init(_ label: String, value: Binding<Double?>, unit: String? = nil, prompt: String? = nil) {}; var body: some View { EmptyView() } }
struct KeyValueRow: View { init(_ key: String, _ value: String) {}; var body: some View { EmptyView() } }
struct SheetAction { let title: String; var role: ButtonRole? = nil; var isEnabled: Bool = true; var isBusy: Bool = false; let action: @MainActor () -> Void }
struct SheetScaffold<Content: View>: View { init(title: String, primary: SheetAction? = nil, secondary: SheetAction? = nil, @ViewBuilder content: () -> Content) {}; var body: some View { EmptyView() } }
extension View { func toastOverlay(_ center: ToastCenter) -> some View { self } }
// Charts
enum ChartCell: Hashable { case text(String), number(Double?, decimals: Int) }
struct ChartTable { let columns: [String]; let rows: [[ChartCell]] }
struct LegendItem: Hashable { let label: String; let color: Color; var dashed: Bool = false }
struct ChartLegend: View { init(_ items: [LegendItem]) {}; var body: some View { EmptyView() } }
struct ChartCard<ChartBody: View>: View { init(title: String, hint: String? = nil, table: ChartTable, height: CGFloat = 260, @ViewBuilder chart: () -> ChartBody) {}; var body: some View { EmptyView() } }
struct ChartPoint: Identifiable, Hashable { let index: Int; let label: String; let value: Double; let series: String; let segment: Int; var id: String { "\(series)-\(segment)-\(index)" } }
enum ChartSeries { static func segments(label: [String], values: [Double?], series: String) -> [ChartPoint] { [] } }
// Shared health cards
struct TotalPartsLine: View { init(total: CompositeScore) {}; var body: some View { EmptyView() } }
struct Le8Card: View { init(indices: HealthIndices, title: String = "心血管健康 Life's Essential 8", subtitle: String? = nil) {}; var body: some View { EmptyView() } }
struct MepaSheet: View { init(mepa: MepaResult) {}; var body: some View { EmptyView() } }
struct WcrfCard: View { init(indices: HealthIndices, subtitle: String? = nil) {}; var body: some View { EmptyView() } }
struct HazardResultRow: View { init(hazard: HazardResult, def: HazardDef?, sources: [SourceDef]) {}; var body: some View { EmptyView() } }
struct ImpactPreviewCard: View { init(preview: DayPreview) {}; var body: some View { EmptyView() } }
struct JobProgressView: View { let hint: (Int) -> String; init(title: String, phase: JobPhase?, startedAt: Date, hint: @escaping (Int) -> String) { self.hint = hint }; var body: some View { EmptyView() } }
// Networking-backed components (WP0-B)
struct RemotePhoto: View { init(photoId: String, side: CGFloat = 72) {}; var body: some View { EmptyView() } }
@MainActor @Observable final class PhotoUploadModel {
    private(set) var photos: [UploadedPhoto] = []
    private(set) var isUploading = false
    let limit: Int
    var ids: [String] { photos.map(\.id) }
    init(api: APIClient, limit: Int = 6, onError: @escaping @MainActor (String) -> Void) { self.limit = limit }
    func add(items: [PhotosPickerItem]) async {}
    func add(image: UIImage) async {}
    func remove(id: String) {}
    func reset() {}
}
struct PhotoUploadStrip: View { init(model: PhotoUploadModel, addLabel: String = "添加照片") {}; var body: some View { EmptyView() } }
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: @MainActor (UIImage) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController { UIImagePickerController() }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
}
```
Additional binding details:
- **`Theme`** must expose every token named in §B.6 as `static let <name>: Color`, plus `static func seq(_ step: Int) -> Color` and `enum Theme.Font` with `h1, h2, h3, body, small, statValue, ringBig, ringSmall`.
- **`ScoreStatus`**: `fill`, `text`, `soft` map to `good/warning/critical/axis` and the `…Text`/`…Soft` variants per web1 §0.5.
- **`ScoreRing.color(for:)`** thresholds: ≥70 `good`, ≥55 `warning`, ≥40 `serious`, otherwise `critical`; `nil` → `axis`.
- **`Meter`** maths per web1 §3.1.
- **`ImpactPreviewCard`** rows and footers per web1 §3.7.
- **`Le8Card`**: the MEPA link opens `MepaSheet` internally.
- **`JobProgressView`** shows `排队中…` when `phase == .queued`, otherwise `title`, then `"\(elapsed)s"`, then `hint(elapsed)` (pulsing).
- **`Seg`** wraps onto multiple lines (FlowLayout); it is not `Picker(.segmented)`.
- **`toastOverlay`**: info toasts last 2.6 s on an ink background; error toasts last 5 s on a critical background with white text; top centre.

#### E.3.5 Patterns every WP copies
These compile against the contract above. `UncheckedSendable` is the `Core/Util` type from §E.3.2.
```swift
import SwiftUI
import HealthKit
import BackgroundTasks

// View + view model skeleton (feature WPs)
@MainActor @Observable final class ExampleModel {
    var day: DayResponse?
    var error: String?
    var isLoading = false
    var jobPhase: JobPhase?
    var draft: MealDraft?
    func load(app: AppState, date: String, member: String?) async {
        isLoading = true; defer { isLoading = false }
        do { day = try await app.api.day(date, user: member); error = nil }
        catch { self.error = APIError.from(error).message }
    }
    // AI job with progress (WP3/WP4/WP6/WP7)
    func analyze(app: AppState, req: MealAIRequest) async {
        do {
            let jobId = try await app.api.startMealAI(req)
            PendingJobStore.save(PendingJob(id: jobId, kind: "meal", createdAt: Date(), context: ["date": req.date]))
            draft = try await JobPoller(api: app.api).wait(jobId: jobId, as: MealDraft.self) { [weak self] p in self?.jobPhase = p }
            PendingJobStore.remove(id: jobId)
        } catch is CancellationError {
            app.toasts.show("已取消")
        } catch {
            app.toasts.error(error)
        }
    }
}
struct ExampleScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = ExampleModel()
    @State private var date = ""
    var body: some View {
        ScrollView { Text(model.day?.date ?? "") }
            .refreshable { await model.load(app: app, date: date.isEmpty ? app.today : date, member: nil) }
            .task(id: "\(date)|\(app.dataVersion)") { await model.load(app: app, date: date.isEmpty ? app.today : date, member: nil) }
    }
}

// Callback API → async (WP9 HealthBackground)
enum ExampleBackground {
    static func observe(store: HKHealthStore, type: HKSampleType) {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
            let done = UncheckedSendable(completion)
            Task { @MainActor in
                await HealthSyncService.current?.syncNow(reason: .observer)
                done.value()
            }
        }
        store.execute(query)
    }
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.nutrilog.ios.healthsync.refresh", using: nil) { task in
            let box = UncheckedSendable(task)
            let work = Task { @MainActor in
                await HealthSyncService.current?.syncNow(reason: .backgroundRefresh)
                box.value.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
}
```

#### E.3.6 Seeded stubs (created by WP0-B at final paths; ownership per §B.1)
| Stub type (signature as in §E.3.3) | Path | Owner |
|---|---|---|
| `LoginScreen()` | `Features/Auth/LoginScreen.swift` | WP1 |
| `OnboardingScreen()` | `Features/Auth/OnboardingScreen.swift` | WP1 |
| `MoreScreen()` | `Features/More/MoreScreen.swift` | WP1 |
| `ShareSettingsScreen()` | `Features/More/ShareSettingsScreen.swift` | WP1 |
| `TodayScreen(member:)` | `Features/Today/TodayScreen.swift` | WP2 |
| `LogMealScreen(request:)` | `Features/LogMeal/LogMealScreen.swift` | WP3 |
| `BodyScreen()` | `Features/Body/BodyScreen.swift` | WP4 |
| `ActivityRecognizerSheet(date:current:mode:onDone:)` | `Features/Body/ActivityRecognizerSheet.swift` | WP4 |
| `TrendsScreen(member:)` | `Features/Trends/TrendsScreen.swift` | WP5 |
| `ReportsScreen()` | `Features/Reports/ReportsScreen.swift` | WP6 |
| `CommunityScreen()` | `Features/Community/CommunityScreen.swift` | WP6 |
| `FoodsScreen()` | `Features/Foods/FoodsScreen.swift` | WP7 |
| `StandardsScreen(initialTab:)` | `Features/Standards/StandardsScreen.swift` | WP8 |
| `HealthSyncScreen()` | `Features/HealthSync/HealthSyncScreen.swift` | WP9 |
| `HealthPrefillButton(onPrefill:)` + `ProfilePrefill` | `Features/HealthSync/HealthPrefillButton.swift` | WP9 |
| `HealthSyncService` (whole class API) | `Core/Health/HealthSyncService.swift` | WP9 |

### E.4 Collaboration rules
1. **Ownership.** Edit only files your WP owns. If you need a change in someone else's file (a missing model field, a new `APIClient` method, a component tweak), ask that owner through the orchestrator. Do not work around it with duplicates.
2. **New shared API** goes through the WP0 owner even during Phase 1. Additions are allowed; renames are not.
3. **Unique names.** Every type outside `private` scope is prefixed with its feature name (§A.10). Before creating a new top-level type, grep the tree.
4. **Strings.** Copy Chinese strings from the spec section cited in your WP. Copy them; don't retype or "improve" them.
5. **Gate.** Each WP runs `scripts/verify.sh` before hand-off and reports the output.
6. **No project-file edits.** Folders are synchronized, so creating files in your directories is enough.

---

## F. Verification plan

### F.1 Primary gate: `ios/scripts/verify.sh` (WP0-A writes it; everyone runs it)
```bash
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
  xcodebuild -project NutriLog.xcodeproj -scheme NutriLog -configuration Debug -sdk iphoneos \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet
fi
echo "verify: OK"
```
- **Step 2** is the primary gate, verified working on this Mac: `swiftc -typecheck … -sdk $(xcrun --sdk iphoneos --show-sdk-path) -target arm64-apple-ios17.0`.
- **Step 3 is mandatory.** The prototype showed `-typecheck` passing code that `xcodebuild` rejected with `passing closure as a 'sending' parameter risks causing data races`.
- **Step 5** is the secondary gate. It was verified working with the §A.5 project (`BUILD SUCCEEDED`, unsigned). Add `build/` to `.gitignore`.
- **Warnings are not errors**, but any new `warning:` from steps 2–3 in your own files should be fixed.

### F.2 Logic tests (`scripts/logic-tests.sh`), runtime checks without a simulator
For each folder `LogicTests/<Suite>/`:
```bash
xcrun swiftc -swift-version 6 -module-name LogicTests LogicTests/Harness.swift $(cat LogicTests/<Suite>/sources.txt) LogicTests/<Suite>/main.swift -o build/logic-<Suite> && build/logic-<Suite>
```
- Each `sources.txt` lists **Foundation-only** (HealthKit is allowed for `Health`) source files relative to `ios/`, e.g. `NutriLog/Core/Models/Common.swift`.
- macOS can import HealthKit; this was verified.
- Suites:
  - `Core` (WP0-A): format, dates, timestamps, `ItemMath`, model decoding fixtures.
  - `Health` (WP9): sleep, workout mapping, day aggregation.
  - `Trends` (WP5): bucketing.
- A failing check prints `FAIL <name>: <detail>` and exits 1.

### F.3 Optional tertiary: simulator
Simulator runtimes were listed on this Mac (iOS 27.0: iPhone 17, 18 Pro, …) but are not guaranteed to boot. Optional:
```bash
xcodebuild -project NutriLog.xcodeproj -scheme NutriLog -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build
```
HealthKit in the simulator has no real data; use the Health app's "Add Data" for spot checks.

### F.4 Server verification (WP-S)
- `cd aaaaa && npm install && npm test && npm run typecheck`. **Node is not installed on this Mac**; this requires `brew install node` (≥ 22.13), which is noted but must not be run by agents without approval.
- §C.10 lists the cases.
- **Manual web regression on a local server** (`npm run seed:demo -w server`, then `npm run dev`): log in as `demo`, then check that Today, Log Meal (AI mock), Body (weight, exercise, activity form, labs), Trends, Reports, Foods, Community, Standards and Settings look and behave exactly as before.

### F.5 Device QA checklist (after GATE-FINAL; needs a signing team)
1. Login and register with the invite code against `http://45.63.23.52:8787`. A wrong password shows `用户名或密码错误`. Killing and relaunching the app keeps the session.
2. Onboarding prefill from Health saves the profile. Today's `today` follows the profile time zone.
3. Log a meal with a camera photo (HEIC→JPEG upload succeeds). The AI job shows progress; edit grams; the preview updates; save; Today updates.
4. Edit and delete a meal; water ±250.
5. Body: weight, exercise, activity form clear, labs in mmol/L. The values appear on the web, which uses the same server.
6. Health sync:
   - Enable it; the 90-day backfill completes; steps and energy match the Health app for 3 sample days.
   - Edit a synced day's sleep on the web; the next sync keeps it (`kept_manual` shown).
   - Delete a weight in Health; it disappears from the server.
   - Lock the phone for 1 hour while walking; background delivery syncs (check `上次同步`).
7. Trends 全部 (≈3 MB) loads without UI stalls. Reports AI 点评 generates (non-mock server).
8. Community member day is read-only with no photos. Share settings round-trip all 5 fields.
9. 登录设备 shows `本机`. Revoking another device works.
10. 删除账号 with the wrong password shows an error. With the correct password, the app returns to Login and the account is gone on the web (needs WP-S deployed).
11. Dark mode and the 外观 override; VoiceOver labels on the ring, bars and meal icons.

### F.6 Release blockers (tracked, not part of the build gate)
- **RB-1:** HTTPS plus a domain, then remove `NSAllowsArbitraryLoads` (§A.8).
- **RB-2:** deploy WP-S, which provides in-app account deletion (App Store 5.1.1(v)) and HealthKit sync.
- **RB-3:** App Store HealthKit review. Usage strings are present, data is used only for app functionality, and health data is never used for advertising. The privacy policy URL must state that data goes to the user's chosen server and that meal text, photos and Health-derived values are sent to the AI provider (Anthropic). The in-app link (更多 → 关于, the login screen) and the App Store Connect metadata must both point to it: set `NLPrivacyPolicyURL` (`scripts/release-check.sh` fails while it is empty).
- **RB-4:** set `DEVELOPMENT_TEAM` and enable the HealthKit capability in the developer portal for `com.nutrilog.ios`.
- **RB-5:** App Store 5.1.2(i) and 1.2. Third-party AI: the usage strings and the consent alert name Anthropic, AI requests ask first (§C.13), and the privacy policy names Anthropic as a processor. User-generated content: 举报 (mail to `NLSupportEmail`) and 屏蔽 on community cards and other members' foods, 更多 → 已屏蔽的成员, and an operator commitment to act on reports. Set `NLSupportEmail` (`scripts/release-check.sh`).
- `ITSAppUsesNonExemptEncryption = NO` is set (§A.6); revisit it if non-OS cryptography is ever added.
