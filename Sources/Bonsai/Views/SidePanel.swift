import SwiftUI

struct SidePanel: View {
    @Environment(AppState.self) private var state
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 26)

            Text("COMPRESSION LEVEL")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(theme.text3)
                .padding(.bottom, 10)

            VStack(spacing: 10) {
                ForEach(Preset.allCases) { preset in
                    PresetCard(preset: preset)
                }
            }

            infoNote
                .padding(.top, 14)

            if !Compressor.usesGhostscript {
                engineHint
                    .padding(.top, 8)
            }

            Spacer(minLength: 16)

            bottomSection
        }
        .padding(Layout.inset)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            // The real app icon, straight from the bundle.
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .shadow(color: theme.shadow, radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bonsai")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.text)
                Text("PDF compressor")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
            }
            Spacer()
            ThemeToggle()
        }
    }

    // MARK: contextual note

    private var infoNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Icon(name: "info-circle", size: 14)
                .foregroundStyle(theme.accent)
                .padding(.top, 1)
            Text(noteText)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1))
        )
        .animation(.easeInOut(duration: 0.25), value: state.preset)
    }

    /// Shown when Ghostscript is not installed: the native engine can't
    /// recompress JPEG-with-transparency images (common in design exports).
    private var engineHint: some View {
        HStack(alignment: .top, spacing: 9) {
            Icon(name: "bolt", size: 13)
                .foregroundStyle(theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("Basic engine active. For much stronger compression install Ghostscript:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install ghostscript qpdf", forType: .string)
                } label: {
                    Text("brew install ghostscript qpdf")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .help("Click to copy the command, then paste it in Terminal and relaunch the app")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.warning.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.warning.opacity(0.25), lineWidth: 1))
        )
    }

    private var noteText: String {
        switch state.preset {
        case .low:
            "Photos stay visually identical, text and vector graphics are untouched. Great for archiving."
        case .recommended:
            "Images are resampled to 120 DPI, crisp on any screen. Text always stays sharp vector."
        case .extreme:
            "Smallest possible file. Photos may look noticeably softer. Best for email attachments."
        }
    }

    // MARK: bottom: summary + save mode + CTA / success

    @ViewBuilder
    private var bottomSection: some View {
        if let run = state.lastRun {
            SuccessCard(run: run)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !state.pendingItems.isEmpty {
                    summary
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    saveModePicker
                }
                compressButton
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(Format.size(state.totalInputBytes))
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)
                    .strikethrough(state.totalEstimatedBytes != nil, color: theme.text3)
                Icon(name: "arrow-right", size: 12)
                    .foregroundStyle(theme.text3)
                if let est = state.totalEstimatedBytes {
                    Text(Format.size(est))
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(theme.text)
                        .contentTransition(.numericText(value: Double(est)))
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: est)
                } else {
                    Shimmer(width: 74, height: 18)
                }
            }
            if let est = state.totalEstimatedBytes, state.totalInputBytes > 0 {
                let saved = max(0, state.totalInputBytes - est)
                let frac = Double(saved) / Double(state.totalInputBytes)
                Text(saved > 0
                     ? "You'll save \(Format.size(saved)) (−\(Format.percent(frac)))"
                     : "Files are already optimized")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(saved > 0 ? theme.success : theme.text2)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: saved)
            } else {
                Text("Measuring real savings…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1))
        )
    }

    private var saveModePicker: some View {
        HStack(spacing: 6) {
            ForEach(SaveMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.saveMode = mode
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: state.saveMode == mode ? .semibold : .regular))
                        .foregroundStyle(state.saveMode == mode ? theme.text : theme.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(state.saveMode == mode ? theme.surface : .clear)
                                .shadow(color: theme.shadow.opacity(state.saveMode == mode ? 0.8 : 0),
                                        radius: 3, y: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.help)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.wellBG)
        )
    }

    private var compressButton: some View {
        Button {
            state.compressAll()
        } label: {
            HStack(spacing: 9) {
                if state.isCompressing {
                    SpinnerRing(size: 16, line: 2)
                        .foregroundStyle(.white)
                    Text("Compressing…")
                } else {
                    let n = state.pendingItems.count
                    Text(n > 1 ? "Compress \(n) PDFs" : "Compress PDF")
                        .contentTransition(.numericText())
                    Icon(name: "arrow-right", size: 15)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!state.canCompress)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.isCompressing)
    }
}

// MARK: - Success card

struct SuccessCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let run: (files: Int, savedBytes: Int64)

    var body: some View {
        VStack(spacing: 12) {
            AnimatedCheck(color: theme.success, size: 46)
            Text(run.savedBytes > 0
                 ? "Saved \(Format.size(run.savedBytes))"
                 : "Done")
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(theme.text)
            Text("\(run.files) \(run.files == 1 ? "file" : "files") compressed")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)

            HStack(spacing: 8) {
                Button {
                    state.revealSaved()
                } label: {
                    HStack(spacing: 5) {
                        Icon(name: "folder", size: 12)
                        Text("Show in Finder")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                Button {
                    state.clearAll()
                } label: {
                    Text("Clear")
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.successSoft.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.success.opacity(0.25), lineWidth: 1))
        )
    }
}

// MARK: - Preset card

struct PresetCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let preset: Preset
    @State private var hovering = false

    private var selected: Bool { state.preset == preset }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                state.preset = preset
            }
        } label: {
            HStack(spacing: 12) {
                radio
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? theme.accent : theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                        // Real total output size for this preset, live.
                        if !state.items.isEmpty {
                            if let bytes = state.presetTotalBytes(preset) {
                                Text("(\(Format.size(bytes)))")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .foregroundStyle(selected ? theme.accent.opacity(0.85) : theme.text2)
                                    .contentTransition(.numericText())
                                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: bytes)
                                    .transition(.opacity)
                            } else {
                                Shimmer(width: 52, height: 12)
                            }
                        }
                    }
                    Text(preset.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
                Icon(name: preset.icon, size: 16)
                    .foregroundStyle(selected ? theme.accent : theme.text3)
                    .scaleEffect(selected ? 1.1 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? theme.accentSoft : (hovering ? theme.surface2 : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.accent : theme.border,
                                  lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering && !selected ? 1.015 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selected)
        .onHover { hovering = $0 }
    }

    private var radio: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? theme.accent : theme.borderStrong, lineWidth: selected ? 6 : 1.5)
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - Day / Night toggle

struct ThemeToggle: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            themeStore.toggle()
        } label: {
            ZStack {
                Icon(name: "sun", size: 15)
                    .opacity(theme.isNight ? 0 : 1)
                    .rotationEffect(.degrees(theme.isNight ? 90 : 0))
                    .scaleEffect(theme.isNight ? 0.4 : 1)
                Icon(name: "moon", size: 14)
                    .opacity(theme.isNight ? 1 : 0)
                    .rotationEffect(.degrees(theme.isNight ? 0 : -90))
                    .scaleEffect(theme.isNight ? 1 : 0.4)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: theme.isNight)
        }
        .buttonStyle(CircleIconButtonStyle(diameter: 30))
        .focusEffectDisabled()
        .help(theme.isNight ? "Switch to Day" : "Switch to Night")
    }
}
