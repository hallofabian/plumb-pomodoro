import AppKit
import SwiftUI

// Design language inspired by teenage engineering's catalogue style: a monochrome
// industrial palette, hairline rules instead of containers, zero radius, no
// shadows or gradients, thin type, lowercase labels. The only colour is a
// single amber "LED" that marks live state (timer running, hover, focus).

enum TE {
    // MARK: Colour tokens (light / dark)

    static let canvas = dynamic(0xF6F8F7, 0x0F0E12)
    /// Raised island on the canvas (inputs, panel body).
    static let surface = dynamic(0xFFFFFF, 0x18171C)
    static let ink = dynamic(0x000000, 0xF6F8F7)
    /// Secondary text and placeholders; about 6:1 on canvas in both themes.
    static let inkSecondary = dynamic(0x5E5E5E, 0xB2B2B2)
    /// Disabled text and quiet rules.
    static let inkMuted = dynamic(0xB2B2B2, 0x5C5B61)
    static let hairline = dynamic(0xE5E5E5, 0x2A292F)
    static let signal = dynamic(0xF0A800, 0xF0A800)

    static let nsCanvas = nsDynamic(0xF6F8F7, 0x0F0E12)
    static let nsInk = nsDynamic(0x000000, 0xF6F8F7)

    // MARK: Type

    /// Running text, labels, controls.
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .light) }
    /// Headings at 19 pt and up.
    static func heading(_ size: CGFloat = 19) -> Font { .system(size: size, weight: .light) }
    /// Large readouts: the timer, stat figures.
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .thin).monospacedDigit() }
    /// Small uppercase codes, like the markings on a device.
    static let code = Font.system(size: 10, weight: .regular).monospacedDigit()

    // MARK: Spacing

    static let s1: CGFloat = 8
    static let s2: CGFloat = 15
    static let s3: CGFloat = 22
    static let s4: CGFloat = 33

    // MARK: Helpers

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: nsDynamic(light, dark)) }

    private static func nsDynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Structure

/// A 1 pt rule. `strong` uses ink, otherwise the light hairline.
struct Rule: View {
    var strong = false
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(strong ? TE.ink : TE.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// Uppercase device-style marking, e.g. "WORK" or "TODAY".
struct Code: View {
    let text: String
    var color: Color = TE.inkSecondary

    init(_ text: String, color: Color = TE.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased(with: AppLanguage.locale)).font(TE.code).tracking(1.2).foregroundStyle(color)
            .accessibilityLabel(text)
    }
}

/// A settings section: an uppercase code over a strong rule, rows below.
struct TESection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Code(title, color: TE.ink).padding(.bottom, 6)
            Rule(strong: true)
            content
            if let note {
                Text(note)
                    .font(TE.body(11))
                    .foregroundStyle(TE.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, TE.s1)
            }
        }
    }
}

/// Label on the left, control on the right, hairline below.
struct TERow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: TE.s2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(TE.body()).foregroundStyle(TE.ink)
                    if let detail {
                        Text(detail).font(TE.body(11)).foregroundStyle(TE.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: TE.s2)
                control.environment(\.controlLabel, label)
            }
            .padding(.vertical, 10)
            Rule()
        }
    }
}

/// Scrollable page of sections on the canvas.
struct TEPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TE.s4) { content }
                .padding(TE.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TE.canvas)
    }
}

/// Small square status lamp.
struct LED: View {
    var on: Bool
    var size: CGFloat = 7

    var body: some View {
        Rectangle()
            .fill(on ? TE.signal : Color.clear)
            .overlay(Rectangle().strokeBorder(on ? TE.signal : TE.inkMuted, lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Accessibility

private struct ControlLabelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row label around a control, so VoiceOver can say what it adjusts.
    var controlLabel: String? {
        get { self[ControlLabelKey.self] }
        set { self[ControlLabelKey.self] = newValue }
    }
}

extension View {
    /// Applies the surrounding row's label, or `fallback`, as the VoiceOver label.
    func controlAccessibilityLabel(_ label: String?) -> some View {
        modifier(ControlLabelModifier(fallback: label))
    }
}

private struct ControlLabelModifier: ViewModifier {
    let fallback: String?
    @Environment(\.controlLabel) private var label

    func body(content: Content) -> some View {
        if let text = label ?? fallback { content.accessibilityLabel(text) } else { content }
    }
}

// MARK: - Controls

enum TEButtonKind { case primary, secondary, text }

/// Square buttons: solid ink, ink outline, or bare text.
struct TEButtonStyle: ButtonStyle {
    var kind: TEButtonKind = .secondary
    var expand = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, expand: expand, isEnabled: isEnabled)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: TEButtonKind
        let expand: Bool
        let isEnabled: Bool
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(TE.body())
                .lineLimit(1)
                .frame(maxWidth: expand ? .infinity : nil)
                .padding(.horizontal, kind == .text ? 0 : 14)
                .padding(.vertical, kind == .text ? 2 : 7)
                .foregroundStyle(foreground(pressed))
                .background(background(pressed))
                .overlay {
                    if kind == .secondary { Rectangle().strokeBorder(isEnabled ? TE.ink : TE.inkMuted, lineWidth: 1) }
                }
                .overlay(alignment: .bottom) {
                    if kind == .text, hover, isEnabled { Rule(strong: true) }
                }
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }

        private func foreground(_ pressed: Bool) -> Color {
            guard isEnabled else { return TE.inkMuted }
            switch kind {
            case .primary: return TE.canvas
            case .secondary: return pressed ? TE.canvas : TE.ink
            case .text: return pressed ? TE.inkSecondary : TE.ink
            }
        }

        private func background(_ pressed: Bool) -> Color {
            switch kind {
            case .primary: return isEnabled ? (pressed ? TE.inkSecondary : TE.ink) : TE.hairline
            case .secondary: return pressed ? TE.ink : (hover && isEnabled ? TE.hairline : .clear)
            case .text: return .clear
            }
        }
    }
}

extension View {
    func teButton(_ kind: TEButtonKind = .secondary, expand: Bool = false) -> some View {
        buttonStyle(TEButtonStyle(kind: kind, expand: expand))
    }
}

/// Square slide switch. On: ink track with a canvas block on the right.
struct TEToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // The row shows the label; here it is only spoken (see accessibilityRepresentation).
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Rectangle().fill(configuration.isOn ? TE.ink : Color.clear)
                Rectangle().fill(configuration.isOn ? TE.canvas : TE.ink)
                    .frame(width: 12, height: 12)
                    .padding(3)
            }
            .frame(width: 36, height: 18)
            .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Toggle laid out as a settings row.
struct TEToggleRow: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        TERow(label: label, detail: detail) {
            Toggle(label, isOn: $isOn).toggleStyle(TEToggleStyle()).labelsHidden().fixedSize()
        }
    }
}

/// Segmented control: square cells with ink outline, selected cell inverted.
struct TESegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(TE.body(12))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? TE.canvas : TE.ink)
                        .background(selected ? TE.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < options.count - 1 { Rule(strong: true, vertical: true) }
            }
        }
        .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.segmented)
        }
        .controlAccessibilityLabel(nil)
    }
}

/// "–  value  +" with square cells.
struct TEStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = ""
    var zeroLabel: String?

    var body: some View {
        HStack(spacing: 0) {
            cell("−") { value = max(range.lowerBound, value - 1) }.disabled(value <= range.lowerBound)
            Rule(strong: true, vertical: true)
            Text(value == 0 && zeroLabel != nil ? L(zeroLabel!) : "\(value)\(unit.isEmpty ? "" : " " + L(unit))")
                .font(TE.body().monospacedDigit())
                .frame(minWidth: 64)
                .padding(.horizontal, 6)
            Rule(strong: true, vertical: true)
            cell("+") { value = min(range.upperBound, value + 1) }.disabled(value >= range.upperBound)
        }
        .frame(height: 26)
        .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .controlAccessibilityLabel(nil)
        .accessibilityValue(value == 0 && zeroLabel != nil ? L(zeroLabel!) : "\(value)\(unit.isEmpty ? "" : " " + L(unit))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private func cell(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(TE.body(14)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TE.ink)
    }
}

/// Drop-down: current value in an outlined box with a small marker.
struct TEMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var minWidth: CGFloat = 140

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.1) { selection = option.0 }
            }
        } label: {
            HStack(spacing: TE.s1) {
                Text(options.first { $0.0 == selection }?.1 ?? "–").font(TE.body()).lineLimit(1)
                Spacer(minLength: TE.s1)
                Text("▾").font(TE.body(10))
            }
            .foregroundStyle(TE.ink)
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, minHeight: 26)
            .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlAccessibilityLabel(nil)
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    }
}

/// Text field: surface fill, hairline outline that turns ink on focus.
struct TEFieldStyle: TextFieldStyle {
    var large = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        FieldBody(field: configuration, large: large)
    }

    private struct FieldBody<Field: View>: View {
        let field: Field
        let large: Bool
        @FocusState private var focused: Bool

        var body: some View {
            field
                .textFieldStyle(.plain)
                .font(large ? TE.heading() : TE.body())
                .foregroundStyle(TE.ink)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, large ? 8 : 6)
                .background(TE.surface)
                .overlay(Rectangle().strokeBorder(focused ? TE.ink : TE.hairline, lineWidth: 1))
        }
    }
}

extension View {
    func teField(large: Bool = false) -> some View { textFieldStyle(TEFieldStyle(large: large)) }
}

/// Hairline track with a square block handle.
struct TESlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 12
            ZStack(alignment: .leading) {
                Rule(strong: true).frame(width: geo.size.width)
                Rectangle().fill(TE.ink).frame(width: max(0, width * value), height: 3)
                Rectangle().fill(TE.canvas)
                    .overlay(Rectangle().strokeBorder(TE.ink, lineWidth: 1))
                    .frame(width: 12, height: 18)
                    .offset(x: width * value)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = min(1, max(0, (g.location.x - 6) / width))
            })
        }
        .frame(width: 180, height: 18)
        .accessibilityRepresentation { Slider(value: $value, in: 0...1) }
        .controlAccessibilityLabel(nil)
    }
}

/// Inline checkbox: a square that fills with ink.
struct TECheck: View {
    var checked: Bool
    /// For use on an ink background (selected rows).
    var inverted = false

    var body: some View {
        let fill = inverted ? TE.canvas : TE.ink
        Rectangle()
            .fill(checked ? fill : Color.clear)
            .overlay(Rectangle().strokeBorder(checked || inverted ? fill : TE.inkSecondary, lineWidth: 1))
            .overlay {
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .light))
                        .foregroundStyle(inverted ? TE.ink : TE.canvas)
                }
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}

extension Phase {
    /// Lowercase name, as on a device panel.
    var label: String {
        switch self {
        case .work: L("work")
        case .shortBreak: L("short break")
        case .longBreak: L("long break")
        }
    }
}
