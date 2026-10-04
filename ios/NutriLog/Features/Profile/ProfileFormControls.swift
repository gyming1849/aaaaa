import SwiftUI
import UIKit

// MARK: - WP1 form building blocks (web `.field`, `.input`, `.help`, `button.chip`, radio cards; web2 §3.3)
// Shared by Login, Onboarding / ProfileForm and the 更多 settings pages so every form looks the same.

/// Web `.field`: a 13 pt ink-2 label (weight 550) above the control (6 pt gap), then an optional error line
/// (12 pt critical-text) and help text (12 pt ink-3).
struct ProfileField<Content: View>: View {
    let label: String
    let help: String?
    let error: String?
    let content: Content

    init(_ label: String, help: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.error = error
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            if let error, !error.isEmpty { ProfileFieldError(error) }
            if let help, !help.isEmpty { ProfileHelpText(help) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Web `.field .help`: 12 pt ink-3.
struct ProfileHelpText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.foot)
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline validation message: icon + 12 pt critical-text (never colour alone).
struct ProfileFieldError: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.foot)
        .foregroundStyle(Theme.criticalText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Input chrome (web `.input`: 40 pt, radius 10, 1 pt border, surface, 15 pt; focus = accent border + 3 pt accent-soft ring)

private struct ProfileInputChrome: ViewModifier {
    let focused: Bool
    let invalid: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
        content
            .font(Theme.Font.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Theme.surface, in: shape)
            .overlay {
                shape.strokeBorder(invalid ? Theme.critical : (focused ? Theme.accent : Theme.border), lineWidth: 1)
            }
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius + 3, style: .continuous)
                        .stroke(invalid ? Theme.criticalSoft : Theme.accentSoft, lineWidth: 3)
                        .padding(-1.5)
                }
            }
    }
}

extension View {
    /// Web `.input` look for a text field, secure field, picker label or date row.
    func profileInputChrome(focused: Bool = false, invalid: Bool = false) -> some View {
        modifier(ProfileInputChrome(focused: focused, invalid: invalid))
    }
}

/// A single-line text input with the `.input` chrome. The caller owns focus (pass a `FocusState` binding and this field's value).
struct ProfileTextInput<F: Hashable>: View {
    let title: String
    @Binding var text: String
    let prompt: String?
    let field: F
    let focus: FocusState<F?>.Binding
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var submitLabel: SubmitLabel = .next
    var invalid = false
    var maxLength: Int?
    var onSubmit: @MainActor () -> Void = {}

    init(_ title: String, text: Binding<String>, prompt: String? = nil, field: F, focus: FocusState<F?>.Binding,
         contentType: UITextContentType? = nil, keyboard: UIKeyboardType = .default, submitLabel: SubmitLabel = .next,
         invalid: Bool = false, maxLength: Int? = nil, onSubmit: @escaping @MainActor () -> Void = {}) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.field = field
        self.focus = focus
        self.contentType = contentType
        self.keyboard = keyboard
        self.submitLabel = submitLabel
        self.invalid = invalid
        self.maxLength = maxLength
        self.onSubmit = onSubmit
    }

    var body: some View {
        // The visible label sits above the field (web `.field`), so the placeholder is empty unless a prompt is given.
        TextField(title, text: $text, prompt: Text(prompt ?? "").foregroundStyle(Theme.ink3))
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .focused(focus, equals: field)
            .onSubmit { onSubmit() }
            .onChange(of: text) { _, new in
                if let maxLength, new.count > maxLength { text = String(new.prefix(maxLength)) }
            }
            .profileInputChrome(focused: focus.wrappedValue == field, invalid: invalid)
    }
}

/// A password input with the `.input` chrome and a show/hide toggle (eye button, `显示密码` / `隐藏密码`).
struct ProfileSecureInput<F: Hashable>: View {
    let title: String
    @Binding var text: String
    let field: F
    let focus: FocusState<F?>.Binding
    var contentType: UITextContentType = .password
    var submitLabel: SubmitLabel = .done
    var invalid = false
    var onSubmit: @MainActor () -> Void = {}
    @State private var revealed = false

    init(_ title: String, text: Binding<String>, field: F, focus: FocusState<F?>.Binding, contentType: UITextContentType = .password,
         submitLabel: SubmitLabel = .done, invalid: Bool = false, onSubmit: @escaping @MainActor () -> Void = {}) {
        self.title = title
        self._text = text
        self.field = field
        self.focus = focus
        self.contentType = contentType
        self.submitLabel = submitLabel
        self.invalid = invalid
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(title, text: $text, prompt: Text(""))
                } else {
                    SecureField(title, text: $text, prompt: Text(""))
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .focused(focus, equals: field)
            .onSubmit { onSubmit() }

            Button {
                revealed.toggle()
                focus.wrappedValue = field
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(revealed ? "隐藏密码" : "显示密码"))
        }
        .profileInputChrome(focused: focus.wrappedValue == field, invalid: invalid)
    }
}

/// Web `<select class="input">`: a menu showing the selected label with an up/down chevron; the menu lists every option
/// with a checkmark on the current one.
struct ProfileMenuPicker<T: Hashable>: View {
    let title: String
    let options: [SegOption<T>]
    @Binding var selection: T

    init(_ title: String, options: [SegOption<T>], selection: Binding<T>) {
        self.title = title
        self.options = options
        self._selection = selection
    }

    private var currentLabel: String { options.first { $0.value == selection }?.label ?? "—" }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .profileInputChrome()
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(currentLabel))
    }
}

/// Web `button.chip` toggle: capsule 12.5 pt; off = surface-2 / ink-2, on = accent / accent-ink. Optional leading content (avatar).
struct ProfileToggleChip<Leading: View>: View {
    let text: String
    let isOn: Bool
    let leading: Leading
    let action: @MainActor () -> Void

    init(_ text: String, isOn: Bool, action: @escaping @MainActor () -> Void, @ViewBuilder leading: () -> Leading) {
        self.text = text
        self.isOn = isOn
        self.action = action
        self.leading = leading()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                leading
                Text(text).lineLimit(1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .font(Theme.Font.chip)
            .foregroundStyle(isOn ? Theme.accentInk : Theme.ink2)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(isOn ? Theme.accent : Theme.surface2, in: Capsule())
            .overlay { Capsule().strokeBorder(isOn ? Color.clear : Theme.border, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

extension ProfileToggleChip where Leading == EmptyView {
    init(_ text: String, isOn: Bool, action: @escaping @MainActor () -> Void) {
        self.init(text, isOn: isOn, action: action) { EmptyView() }
    }
}

/// Primary / danger submit button with the web spinner replacing the title while busy (`btn primary lg`).
struct ProfileSubmitButton: View {
    let title: String
    var kind: NLButtonStyle.Kind = .primary
    var isBusy = false
    var block = false
    var icon: String?
    let action: @MainActor () -> Void

    init(_ title: String, kind: NLButtonStyle.Kind = .primary, isBusy: Bool = false, block: Bool = false, icon: String? = nil,
         action: @escaping @MainActor () -> Void) {
        self.title = title
        self.kind = kind
        self.isBusy = isBusy
        self.block = block
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 7) {
                    if let icon { Image(systemName: icon).accessibilityHidden(true) }
                    Text(title)
                }
                .opacity(isBusy ? 0 : 1)
                if isBusy {
                    Spinner(track: kind == .primary ? Theme.accentInk.opacity(0.35) : Theme.hair,
                            head: kind == .primary ? Theme.accentInk : Theme.accent)
                }
            }
        }
        .buttonStyle(.nl(kind, size: .lg, block: block))
        .disabled(isBusy)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Page scaffold for the WP1 screens

/// Scrolling page on the `page` background with the iPhone gutter, card spacing, interactive keyboard dismissal and a
/// keyboard `完成` button (the decimal pad has no return key).
struct ProfileScrollPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.gap) { content }
                    .padding(.horizontal, Theme.Metrics.pagePadding)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .debugScrollTo(proxy, ready: true)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.page)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { ProfileKeyboard.dismiss() }
                    .font(.system(size: 16, weight: .semibold))
            }
        }
    }
}

/// Ends editing in the key window (used by keyboard `完成` buttons).
enum ProfileKeyboard {
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The web brand mark: a 34 pt rounded square (radius 10) with a white leaf.
struct ProfileBrandMark: View {
    var background: Color = Theme.accent
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 10 / 34, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "leaf.fill")
                    .font(.system(size: size * 17 / 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
