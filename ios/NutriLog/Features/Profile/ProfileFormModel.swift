import Foundation
import Observation

// MARK: - Profile form state (web `components/ProfileForm.tsx`; web2 §5.6, auth §3.10, §5, §9)

/// Editable copy of a `Profile`. `PUT /profile` is a full replace, so `draft` always carries every field.
/// Client validation mirrors the server rules and reuses its exact messages (auth §3.10, §7).
@MainActor @Observable final class ProfileFormModel {
    enum Field: Hashable, Sendable { case birthDate, height, weight, targetWeight }

    /// Editing an existing profile (Settings: weight label `建档体重` + help) vs creating one (Onboarding: `当前体重`).
    let isEditing: Bool

    /// Switching to 男 only hides `特殊生理阶段` (as on the web); `draft` sends `none` for males, as the server forces.
    var sex: String
    var birthDate: String { didSet { errors[.birthDate] = nil } }
    var heightCm: Double? { didSet { errors[.height] = nil } }
    var weightKg: Double? { didSet { errors[.weight] = nil } }
    var activityLevel: String
    var goal: String
    var goalRate: Double
    var targetWeightKg: Double? { didSet { errors[.targetWeight] = nil } }
    var physiology: String
    var sodiumMode: String
    var conditions: [String]
    var timezone: String
    var nicotine: String
    var secondhandSmoke: Bool

    private(set) var errors: [Field: String] = [:]
    private(set) var isSaving = false

    /// `initial == nil` → the web new-profile defaults (auth §5) with the device time zone (fallback `Asia/Shanghai`).
    init(initial: Profile?, deviceTimeZone: String = TimeZone.current.identifier) {
        let tz = deviceTimeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = initial ?? Profile.newDefault(timezone: tz.isEmpty ? "Asia/Shanghai" : tz)
        isEditing = initial != nil
        sex = p.sex
        birthDate = p.birth_date
        heightCm = p.height_cm
        weightKg = p.weight_kg
        activityLevel = p.activity_level
        goal = p.goal
        goalRate = p.goal_rate_kg_week
        targetWeightKg = p.target_weight_kg
        physiology = p.physiology
        sodiumMode = p.sodium_mode
        conditions = p.conditions
        timezone = p.timezone
        nicotine = p.nicotine
        secondhandSmoke = p.secondhand_smoke
    }

    /// Replaces every field with `p` (after a save, to show what the server stored).
    func load(_ p: Profile) {
        sex = p.sex
        birthDate = p.birth_date
        heightCm = p.height_cm
        weightKg = p.weight_kg
        activityLevel = p.activity_level
        goal = p.goal
        goalRate = p.goal_rate_kg_week
        targetWeightKg = p.target_weight_kg
        physiology = p.physiology
        sodiumMode = p.sodium_mode
        conditions = p.conditions
        timezone = p.timezone
        nicotine = p.nicotine
        secondhandSmoke = p.secondhand_smoke
        errors = [:]
    }

    // MARK: Derived values

    /// The complete profile to send. Conditions are de-duplicated (the server keeps duplicates, auth §3.10), physiology is
    /// `none` for males (as the server forces it), and a hidden, out-of-range target weight (goal = 维持) is dropped
    /// instead of failing on a field the user cannot see.
    var draft: Profile {
        var seen = Set<String>()
        let uniqueConditions = conditions.filter { seen.insert($0).inserted }
        var target = targetWeightKg
        if goal == "maintain", let t = target, !(20...350).contains(t) { target = nil }
        return Profile(sex: sex, birth_date: birthDate, height_cm: heightCm ?? 0, weight_kg: weightKg ?? 0,
                       activity_level: activityLevel, goal: goal, goal_rate_kg_week: goalRate, target_weight_kg: target,
                       physiology: sex == "female" ? physiology : "none", sodium_mode: sodiumMode, conditions: uniqueConditions,
                       timezone: timezone, nicotine: nicotine, secondhand_smoke: secondhandSmoke)
    }

    /// Time-zone picker values (auth §5): the 11 fixed zones, with the current value prepended when it is not one of them.
    var timezoneOptions: [String] {
        Vocab.timezones.contains(timezone) ? Vocab.timezones : [timezone] + Vocab.timezones
    }

    /// `目标速度` options `[0.25, 0.5, 0.75, 1]`, plus the stored value when the server holds another rate (e.g. 0.3).
    var goalRateOptions: [Double] {
        Vocab.goalRates.contains(goalRate) ? Vocab.goalRates : ([goalRate] + Vocab.goalRates).sorted()
    }

    /// `每周 {r} kg（约 {round(r*7700/7)} kcal/天）` with JavaScript number formatting (`0.25`, `1`, `1100`).
    static func goalRateLabel(_ rate: Double) -> String {
        let kcal = (rate * 7700 / 7).rounded(.toNearestOrAwayFromZero)
        return "每周 \(DSFormat.js(rate)) kg（约 \(DSFormat.js(kcal)) kcal/天）"
    }

    /// The device's IANA zone, when it differs from the form's time zone (auth §9: offer to switch).
    var deviceTimeZoneIfDifferent: String? {
        let device = TimeZone.current.identifier
        guard !device.isEmpty, device != timezone, TimeZone(identifier: device) != nil else { return nil }
        return device
    }

    // MARK: Editing helpers

    func toggleCondition(_ key: String) {
        if conditions.contains(key) {
            conditions.removeAll { $0 == key }
        } else {
            conditions.append(key)
        }
    }

    /// Applies values read from Apple Health (WP9 `HealthPrefillButton`): sex, birth date, height and weight when present.
    func apply(_ prefill: ProfilePrefill) {
        if let s = prefill.sex, s == "male" || s == "female" { sex = s }
        if let b = prefill.birth_date, LocalDay.isValid(b) { birthDate = b }
        if let h = prefill.height_cm, h.isFinite, h > 0 { heightCm = (h * 10).rounded() / 10 }
        if let w = prefill.weight_kg, w.isFinite, w > 0 { weightKg = (w * 10).rounded() / 10 }
    }

    // MARK: Validation (auth §3.10 / §9, server wording)

    /// Validates every field; returns the first message, or nil when the form can be sent.
    @discardableResult
    func validate(today: String) -> String? {
        var e: [Field: String] = [:]
        let birth = birthDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if birth.isEmpty {
            e[.birthDate] = "出生日期不能为空"
        } else if !LocalDay.isValid(birth) {
            e[.birthDate] = "出生日期格式应为 YYYY-MM-DD"
        } else if LocalDay.isValid(today), LocalDay.diffDays(birth, today) < 0 {
            e[.birthDate] = Self.futureBirthMessage
        }
        e[.height] = Self.rangeError(heightCm, name: "身高", min: 80, max: 250)
        e[.weight] = Self.rangeError(weightKg, name: "体重", min: 20, max: 350)
        if goal != "maintain", let t = targetWeightKg {
            e[.targetWeight] = Self.rangeError(t, name: "目标体重", min: 20, max: 350)
        }
        errors = e.compactMapValues { $0 }
        let order: [Field] = [.birthDate, .height, .weight, .targetWeight]
        return order.lazy.compactMap { self.errors[$0] }.first
    }

    func error(_ field: Field) -> String? { errors[field] }

    static let futureBirthMessage = "出生日期不能晚于今天"

    /// `{name}不能为空` / `{name}不能小于 {min}` / `{name}不能大于 {max}` (server `num()` messages).
    static func rangeError(_ value: Double?, name: String, min: Double, max: Double) -> String? {
        guard let value, value.isFinite else { return "\(name)不能为空" }
        if value < min { return "\(name)不能小于 \(DSFormat.js(min))" }
        if value > max { return "\(name)不能大于 \(DSFormat.js(max))" }
        return nil
    }

    // MARK: Save

    /// `PUT /profile` with the full object → reload the stored (normalised) profile → toast → `app.didSaveProfile`.
    /// Returns the saved profile, or nil on a validation or server error (both shown as an error toast).
    @discardableResult
    func save(app: AppState) async -> Profile? {
        guard !isSaving else { return nil }
        if let message = validate(today: app.today) {
            app.toasts.error(message)
            return nil
        }
        isSaving = true
        let saved: Profile
        do {
            saved = try await app.api.saveProfile(draft)
        } catch {
            isSaving = false
            app.toasts.error(error)
            return nil
        }
        load(saved)
        isSaving = false
        app.toasts.show("档案已保存，评分已按新档案重新计算")
        await app.didSaveProfile(saved)
        return saved
    }
}
