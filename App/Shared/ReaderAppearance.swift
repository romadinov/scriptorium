import SwiftUI

/// The reader's colours, chosen in the reader rather than following the system: light or dark text pages
/// whatever the device is set to.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TextSize {
    static let range: ClosedRange<Double> = 0.6...3.0
    static func clamp(_ scale: Double) -> Double { min(range.upperBound, max(range.lowerBound, (scale * 20).rounded() / 20)) }
    static func label(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
}

/// The reader's "Aa" panel: a text size slider, the theme, and whatever else the platform adds (layout,
/// View Original Pages). iPad popover, iPhone sheet, Mac popover.
struct ReaderAppearancePanel<Extra: View>: View {
    @Binding var fontScale: Double
    @Binding var theme: ReaderTheme
    /// Text size applies to text books only; page books get just the theme.
    var showsTextSize = true
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsTextSize {
                VStack(spacing: 6) {
                    HStack {
                        Text("Text Size").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(TextSize.label(fontScale)) { fontScale = 1.0 }
                            .monospacedDigit()
                            .help("Back to 100%")
                            .accessibilityLabel("Text size \(TextSize.label(fontScale)), reset to 100%")
                    }
                    HStack(spacing: 10) {
                        Button("Smaller Text", systemImage: "textformat.size.smaller") { fontScale = TextSize.clamp(fontScale - 0.05) }
                            .labelStyle(.iconOnly)
                        Slider(value: Binding(get: { fontScale }, set: { fontScale = TextSize.clamp($0) }),
                               in: TextSize.range)
                            .accessibilityIdentifier("textSize.slider")
                            .accessibilityLabel("Text size")
                        Button("Larger Text", systemImage: "textformat.size.larger") { fontScale = TextSize.clamp(fontScale + 0.05) }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme").font(.subheadline.weight(.semibold))
                Picker("Theme", selection: $theme) {
                    ForEach(ReaderTheme.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            extra
        }
    }
}

extension ReaderAppearancePanel where Extra == EmptyView {
    init(fontScale: Binding<Double>, theme: Binding<ReaderTheme>, showsTextSize: Bool = true) {
        self.init(fontScale: fontScale, theme: theme, showsTextSize: showsTextSize) { EmptyView() }
    }
}
