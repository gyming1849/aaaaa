import SwiftUI

// MARK: - ProfileForm 个人档案表单 (web `components/ProfileForm.tsx`; web2 §5.6, auth §5)
// Used by Onboarding (new profile, submit `开始记录`) and 更多 → 个人档案 (submit `保存`). Single column on iPhone.

struct ProfileFormView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ProfileFormModel
    let submitText: String
    let onSaved: (@MainActor (Profile) -> Void)?

    init(model: ProfileFormModel, submitText: String = "保存", onSaved: (@MainActor (Profile) -> Void)? = nil) {
        self.model = model
        self.submitText = submitText
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sexField
            birthDateField
            VStack(alignment: .leading, spacing: 6) {
                NumberField("身高", value: $model.heightCm, unit: "cm")
                fieldMessages(error: model.error(.height))
            }
            weightField
            activityField
            goalField
                .debugScrollAnchor("goal")
            if model.goal != "maintain" {
                ProfileField("目标速度") {
                    ProfileMenuPicker("目标速度",
                                      options: model.goalRateOptions.map { SegOption(value: $0, label: ProfileFormModel.goalRateLabel($0)) },
                                      selection: $model.goalRate)
                }
                VStack(alignment: .leading, spacing: 6) {
                    NumberField("目标体重", value: $model.targetWeightKg, unit: "kg")
                    fieldMessages(error: model.error(.targetWeight))
                }
            }
            if model.sex == "female" {
                ProfileField("特殊生理阶段",
                             help: "孕期/哺乳期会使用对应的 DRI（如铁 27 mg、叶酸 600 µg），酒精与咖啡因限值更严格，且不建议主动减重。") {
                    Seg(Physiology.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) }, selection: $model.physiology)
                }
            }
            conditionsField
                .debugScrollAnchor("conditions")
            ProfileField("吸烟情况（AHA Life's Essential 8 的“尼古丁暴露”）") {
                ProfileMenuPicker("吸烟情况", options: Nicotine.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) },
                                  selection: $model.nicotine)
            }
            ProfileField("二手烟") {
                Toggle(isOn: $model.secondhandSmoke) {
                    Text("家中有人在室内吸烟")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink1)
                }
                .tint(Theme.accent)
                .frame(minHeight: 40)
            }
            ProfileField("钠上限标准") {
                Seg(SodiumMode.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) }, selection: $model.sodiumMode)
            }
            timezoneField
                .debugScrollAnchor("timezone")
            HStack {
                Spacer(minLength: 0)
                ProfileSubmitButton(submitText, isBusy: model.isSaving) {
                    ProfileKeyboard.dismiss()
                    Task {
                        if let saved = await model.save(app: app) { onSaved?(saved) }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Fields

    private var sexField: some View {
        ProfileField("性别") {
            Seg(Sex.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) }, selection: $model.sex)
        }
    }

    private var birthDateField: some View {
        ProfileField("出生日期", error: model.error(.birthDate)) {
            HStack {
                DatePicker("出生日期", selection: birthDateBinding, in: birthDateRange, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .environment(\.timeZone, ProfileDates.utc)
                    .environment(\.calendar, ProfileDates.calendar)
                    .tint(Theme.accent)
                Spacer(minLength: 0)
                if let age = ProfileDates.age(birth: model.birthDate, today: app.today) {
                    Text(verbatim: "\(age) 岁")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }
            }
        }
    }

    private var weightField: some View {
        VStack(alignment: .leading, spacing: 6) {
            NumberField(model.isEditing ? "建档体重" : "当前体重", value: $model.weightKg, unit: "kg")
            fieldMessages(error: model.error(.weight))
            if model.isEditing {
                ProfileHelpText("日常体重请在“身体与运动”中记录，评分会自动使用最近一次称重")
            }
        }
    }

    private var activityField: some View {
        ProfileField("日常活动水平（NASEM 2023 能量方程分档）",
                     help: "如果连接了“健康”App 的步数/活动能量，每天的消耗会用实测数据，这里只作为没有数据时的基准。") {
            VStack(spacing: 8) {
                ForEach(activityLevels, id: \.key) { level in
                    ProfileActivityCard(title: level.zh, desc: level.desc, isOn: model.activityLevel == level.key) {
                        model.activityLevel = level.key
                    }
                }
            }
        }
    }

    private var goalField: some View {
        ProfileField("目标") {
            Seg(Goal.allCases.map { SegOption(value: $0.rawValue, label: $0.zh) }, selection: $model.goal)
        }
    }

    private var conditionsField: some View {
        ProfileField("健康状况（会收紧相应标准）") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(conditionDefs) { c in
                        ProfileToggleChip(c.zh, isOn: model.conditions.contains(c.key)) { model.toggleCondition(c.key) }
                            .accessibilityHint(Text(c.effect))
                            .contextMenu { Text(c.effect) }
                    }
                }
                let selected = conditionDefs.filter { model.conditions.contains($0.key) }
                if !selected.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(selected) { c in
                            Text(verbatim: "\(c.zh)：\(c.effect)")
                                .font(Theme.Font.foot)
                                .foregroundStyle(Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var timezoneField: some View {
        ProfileField("时区（决定“今天”从何时开始）") {
            ProfileMenuPicker("时区", options: model.timezoneOptions.map { SegOption(value: $0, label: $0) }, selection: $model.timezone)
            if let device = model.deviceTimeZoneIfDifferent {
                Button {
                    model.timezone = device
                } label: {
                    Label { Text(verbatim: "改用本机时区 \(device)") } icon: { Image(systemName: "location") }
                        .font(Theme.Font.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentText)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func fieldMessages(error: String?) -> some View {
        if let error { ProfileFieldError(error) }
    }

    // MARK: Data

    private struct LevelRow { let key: String; let zh: String; let desc: String }

    /// `meta.activityLevels` (zh + desc), falling back to the static web labels before meta has loaded.
    private var activityLevels: [LevelRow] {
        if let levels = app.meta?.activityLevels, !levels.isEmpty {
            return levels.map { LevelRow(key: $0.key, zh: $0.zh, desc: $0.desc) }
        }
        return ActivityLevel.allCases.map { LevelRow(key: $0.rawValue, zh: $0.zh, desc: $0.desc) }
    }

    /// `me.conditions` (fallback `meta.conditions`, then the static list of auth §3.8).
    private var conditionDefs: [ConditionDef] {
        if let c = app.me?.conditions, !c.isEmpty { return c }
        if let c = app.meta?.conditions, !c.isEmpty { return c }
        return ProfileDates.fallbackConditions
    }

    private var birthDateBinding: Binding<Date> {
        Binding(
            get: { ProfileDates.date(model.birthDate) ?? ProfileDates.date("1995-01-01") ?? Date() },
            set: { model.birthDate = LocalDay.key(for: $0, in: ProfileDates.utc) }
        )
    }

    private var birthDateRange: ClosedRange<Date> {
        let lower = ProfileDates.date("1900-01-01") ?? .distantPast
        let upper = ProfileDates.date(app.today) ?? Date()
        return lower...max(lower, upper)
    }
}

/// A selectable activity-level card (web `card flat tight` radio): radio dot + bold title, small muted description;
/// selected = accent border on accent-soft.
private struct ProfileActivityCard: View {
    let title: String
    let desc: String
    let isOn: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(isOn ? Theme.accent : Theme.axis, lineWidth: 1.5)
                    if isOn { Circle().fill(Theme.accent).padding(4) }
                }
                .frame(width: 17, height: 17)
                .padding(.top, 2)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(desc)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Theme.accentSoft : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent : Theme.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Calendar-date helpers for the birth-date picker: `YYYY-MM-DD` strings ↔ UTC midnight, so the picker never shifts a day.
enum ProfileDates {
    static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    static func date(_ key: String) -> Date? { LocalDay.date(fromKey: key, in: utc) }

    /// Whole years between `birth` and `today` (nil for invalid input or a future date).
    static func age(birth: String, today: String) -> Int? {
        guard let b = LocalDay.parts(birth), let t = LocalDay.parts(today) else { return nil }
        var years = t.year - b.year
        if (t.month, t.day) < (b.month, b.day) { years -= 1 }
        return years >= 0 ? years : nil
    }

    /// `me.conditions` as served by the server (auth §3.8), for the rare case where neither `me` nor `meta` carries them.
    static let fallbackConditions: [ConditionDef] = [
        ConditionDef(key: "hypertension", zh: "高血压", effect: "钠上限收紧到 1500 mg（AHA）"),
        ConditionDef(key: "high_ldl", zh: "高胆固醇 / 高 LDL", effect: "饱和脂肪理想值收紧到 6% 能量（AHA）"),
        ConditionDef(key: "diabetes", zh: "糖尿病 / 糖尿病前期", effect: "添加糖上限收紧到 AHA 建议值"),
        ConditionDef(key: "kidney", zh: "慢性肾病", effect: "仅提示：蛋白质、钾、磷目标请遵医嘱，本系统不据此加分"),
        ConditionDef(key: "gout", zh: "痛风 / 高尿酸", effect: "仅提示：注意红肉、海鲜、酒精与含糖饮料"),
    ]
}
