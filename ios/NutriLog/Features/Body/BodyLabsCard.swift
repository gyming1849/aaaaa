import SwiftUI

// MARK: - 体检化验指标 (web1 §7.2 Row 3; body §3.4–§3.6)
// Lab date + unit Seg (mmol/L ×38.67 cholesterol, ×18 glucose → mg/dL on save; HbA1c always %), the five values and two
// flags, `POST /labs`, then the table 日期 | 非 HDL 胆固醇 | 空腹血糖 | HbA1c with delete (`DELETE /labs/{id}`, no confirmation).

struct BodyLabsCard: View {
    @Environment(AppState.self) private var app
    @Bindable var model: BodyModel

    var body: some View {
        Card {
            CardHeader("体检化验指标", hint: "用于美国心脏协会 LE8 的血脂、血糖两项；不填则这两项不计入")
            FlowLayout(spacing: 12, lineSpacing: 10) {
                BodyDateField(nil, date: $model.labForm.date, maxDate: app.today, accessibilityName: "化验日期")
                Seg([SegOption(value: BodyLabUnit.mmol, label: "mmol/L（国内常用）"), SegOption(value: BodyLabUnit.mgdl, label: "mg/dL")],
                    selection: $model.labForm.unit)
            }
            fields
            Button {
                Task { await model.saveLab(app: app) }
            } label: {
                if model.isSavingLab { Spinner() }
                Text("保存化验结果")
            }
            .buttonStyle(.nl())
            .disabled(model.isSavingLab)
            if !model.labs.isEmpty {
                table
            }
        }
    }

    private var fields: some View {
        let u = model.labForm.unitLabel
        return LazyVGrid(columns: BodyGrid.twoColumns, alignment: .leading, spacing: 12) {
            NumberField("总胆固醇", value: $model.labForm.total_chol, unit: u)
            NumberField("高密度脂蛋白 HDL", value: $model.labForm.hdl, unit: u)
            NumberField("低密度脂蛋白 LDL（可选）", value: $model.labForm.ldl, unit: u)
            NumberField("空腹血糖", value: $model.labForm.fasting_glucose, unit: u)
            NumberField("糖化血红蛋白 HbA1c", value: $model.labForm.hba1c, unit: "%")
            VStack(alignment: .leading, spacing: 8) {
                BodyFieldLabel("用药 / 诊断")
                Toggle("服用降脂药", isOn: $model.labForm.lipid_treated).toggleStyle(.bodyCheckbox)
                Toggle("已诊断糖尿病", isOn: $model.labForm.diabetes).toggleStyle(.bodyCheckbox)
            }
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
            GridRow {
                Text("日期")
                Text("非 HDL 胆固醇").gridColumnAlignment(.trailing)
                Text("空腹血糖").gridColumnAlignment(.trailing)
                Text("HbA1c").gridColumnAlignment(.trailing)
                Color.clear.frame(width: 30, height: 1)
            }
            .font(Theme.Font.tableHead)
            .foregroundStyle(Theme.ink3)
            .multilineTextAlignment(.trailing)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(Array(model.labs.enumerated()), id: \.element.id) { i, lab in
                GridRow(alignment: .center) {
                    Text(verbatim: lab.date)
                        .foregroundStyle(Theme.ink1)
                        .lineLimit(1)
                        .fixedSize()
                    cell(lab.non_hdl.map { "\(fmt($0)) mg/dL" } ?? "—", suffix: lab.lipidTreated ? "（服药）" : "")
                    cell(lab.fasting_glucose.map { "\(fmt($0)) mg/dL" } ?? "—", suffix: "")
                    cell(lab.hba1c.map { "\(DSFormat.js($0))%" } ?? "—", suffix: lab.hasDiabetes ? "（糖尿病）" : "")
                    BodyDeleteButton { delete(lab) }
                }
                .font(Theme.Font.meter)
                .monospacedDigit()
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: Text("删除")) { delete(lab) }
                if i < model.labs.count - 1 {
                    Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private func delete(_ lab: LabResult) {
        Task { await model.deleteLab(lab, app: app) }
    }

    private func cell(_ value: String, suffix: String) -> some View {
        Text(verbatim: value + suffix)
            .foregroundStyle(Theme.ink1)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
