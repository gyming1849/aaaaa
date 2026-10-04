import SwiftUI

// MARK: - SheetScaffold (web1 §3.3 Modal → iOS sheet): inline title with a close "×" (aria `关闭`), a scrolling body
// (padding 18×20 on surface), and an optional footer with the secondary and primary actions (right-aligned,
// hairline on top). Re-installs the toast overlay so toasts raised while the sheet is up appear on top of it.

struct SheetAction {
    let title: String
    var role: ButtonRole? = nil
    var isEnabled: Bool = true
    var isBusy: Bool = false
    /// Optional SF Symbol shown before the title (e.g. `checkmark`, `sparkles`, `bookmark`).
    var icon: String? = nil
    let action: @MainActor () -> Void

    init(title: String, role: ButtonRole? = nil, isEnabled: Bool = true, isBusy: Bool = false, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.role = role
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.action = action
    }

    init(title: String, icon: String?, role: ButtonRole? = nil, isEnabled: Bool = true, isBusy: Bool = false, action: @escaping @MainActor () -> Void) {
        self.init(title: title, role: role, isEnabled: isEnabled, isBusy: isBusy, action: action)
        self.icon = icon
    }
}

struct SheetScaffold<Content: View>: View {
    let title: String
    let primary: SheetAction?
    let secondary: SheetAction?
    let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    init(title: String, primary: SheetAction? = nil, secondary: SheetAction? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.primary = primary
        self.secondary = secondary
        self.content = content()
    }

    var body: some View {
        let base = NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.surface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if primary != nil || secondary != nil { footer }
            }
        }
        .tint(Theme.accent)

        if let toasts {
            base.toastOverlay(toasts)
        } else {
            base
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hair).frame(height: 1)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if let secondary { button(secondary, isPrimary: false) }
                if let primary { button(primary, isPrimary: true) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.surface)
    }

    private func button(_ a: SheetAction, isPrimary: Bool) -> some View {
        let kind: NLButtonStyle.Kind = a.role == .destructive ? .danger : (isPrimary ? .primary : .plain)
        return Button(role: a.role) {
            a.action()
        } label: {
            if a.isBusy {
                Spinner(track: isPrimary ? Theme.accentInk.opacity(0.35) : Theme.hair, head: isPrimary ? Theme.accentInk : Theme.accent)
            } else if let icon = a.icon {
                Image(systemName: icon)
            }
            Text(a.title)
        }
        .buttonStyle(.nl(kind, size: .lg))
        .disabled(!a.isEnabled || a.isBusy)
    }
}

private struct SheetScaffoldPreview: View {
    @State private var shown = true
    @State private var busy = false
    var body: some View {
        Button("打开") { shown = true }
            .buttonStyle(.nl(.primary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page)
            .sheet(isPresented: $shown) {
                SheetScaffold(title: "存入食物库",
                              primary: SheetAction(title: "保存", icon: "bookmark", isBusy: busy) { busy.toggle() },
                              secondary: SheetAction(title: "取消") { shown = false }) {
                    Text(verbatim: "按每 100 g 的营养数据保存。下次记录时说出名称会自动匹配，也可以在“从食物库添加”里直接选择克数。")
                        .font(Theme.Font.small).foregroundStyle(Theme.ink2)
                    NumberField("一份的重量", value: .constant(200), unit: "g")
                }
            }
    }
}

#Preview("SheetScaffold") { SheetScaffoldPreview() }

#Preview("SheetScaffold · 深色") { SheetScaffoldPreview().preferredColorScheme(.dark) }
