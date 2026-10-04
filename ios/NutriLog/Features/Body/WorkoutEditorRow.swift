import SwiftUI

// MARK: - One editable workout in the ActivityRecognizer draft (web1 §6 "Each workout card").
// Description (aria 描述) · activity picker (aria 运动类型; choosing one resets MET to the table value) · delete (aria 删除);
// 时长 … 分钟 · MET · 距离 … km (empty shown for 0) · 平均心率 · 净消耗约 {kcal} kcal（设备显示 …）;
// checkbox 已含在设备活动能量中（避免重复计算）; notes. Empty numeric fields read as 0, like the web's `Number("")`.

struct WorkoutEditorRow: View {
    @Binding var workout: WorkoutDraft
    let activities: [ActivityDef]
    /// Profile weight for the local estimate (`profile.weight_kg ?? 65`).
    let weightKg: Double
    let onDelete: @MainActor () -> Void

    init(workout: Binding<WorkoutDraft>, activities: [ActivityDef], weightKg: Double, onDelete: @escaping @MainActor () -> Void) {
        self._workout = workout
        self.activities = activities
        self.weightKg = weightKg
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("描述", text: $workout.description)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ink)
                    .bodyInputChrome()
                    .accessibilityLabel(Text("描述"))
                BodyDeleteButton(action: onDelete)
            }
            activityPicker
            FlowLayout(spacing: 12, lineSpacing: 8) {
                labeled("时长") {
                    NumberField("", value: zeroAsEmpty(\.duration_min), unit: "分钟").accessibilityLabel(Text("时长")).frame(width: 112)
                }
                labeled("MET") {
                    NumberField("", value: zeroAsEmpty(\.met)).accessibilityLabel(Text(verbatim: "MET")).frame(width: 76)
                }
                labeled("距离") {
                    NumberField("", value: distance, unit: "km").accessibilityLabel(Text("距离")).frame(width: 100)
                }
            }
            estimateLine
            Toggle("已含在设备活动能量中（避免重复计算）", isOn: $workout.in_device)
                .toggleStyle(.bodyCheckbox)
            if let notes = workout.notes, !notes.isEmpty {
                Text(verbatim: notes)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    // MARK: Pieces

    private var activityPicker: some View {
        BodyMenuPicker("运动类型", selection: Binding(get: { workout.activity_key }, set: { key in
            workout.activity_key = key
            if let a = activities.first(where: { $0.key == key }) { workout.met = a.met }
        }), options: activities.map { BodyPickerOption(key: $0.key, label: $0.zh) })
    }

    private var estimateLine: some View {
        FlowLayout(spacing: 12, lineSpacing: 4) {
            if let hr = workout.avg_hr, hr != 0 {
                Text(verbatim: "平均心率 \(DSFormat.js(hr))")
                    .foregroundStyle(Theme.ink3)
            }
            Text(estimate)
                .foregroundStyle(Theme.ink1)
                .monospacedDigit()
        }
        .font(Theme.Font.small)
    }

    /// `净消耗约 **{fmt(kcal)}** kcal` + muted `（设备显示 {fmt(device_kcal)}）`.
    private var estimate: AttributedString {
        let kcal = ActivityRecognizerModel.kcal(met: workout.met, durationMin: workout.duration_min, weightKg: weightKg)
        var out = AttributedString("净消耗约 ")
        var value = AttributedString(fmt(kcal))
        value.inlinePresentationIntent = .stronglyEmphasized
        out += value
        out += AttributedString(" kcal")
        if let device = workout.device_kcal, device != 0 {
            var muted = AttributedString("（设备显示 \(fmt(device))）")
            muted.foregroundColor = Theme.ink3
            out += muted
        }
        return out
    }

    private func labeled<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.ink2)
            field()
        }
    }

    /// Duration and MET: 0 (the web's `Number("")`) is shown as an empty field; clearing stores 0.
    private func zeroAsEmpty(_ keyPath: WritableKeyPath<WorkoutDraft, Double>) -> Binding<Double?> {
        Binding(get: { workout[keyPath: keyPath] == 0 ? nil : workout[keyPath: keyPath] },
                set: { workout[keyPath: keyPath] = $0 ?? 0 })
    }

    /// Distance: empty when 0 or unknown (web `value={w.distance_km || ""}`); clearing stores 0 (the server stores null).
    private var distance: Binding<Double?> {
        Binding(get: { (workout.distance_km ?? 0) == 0 ? nil : workout.distance_km },
                set: { workout.distance_km = $0 ?? 0 })
    }
}
