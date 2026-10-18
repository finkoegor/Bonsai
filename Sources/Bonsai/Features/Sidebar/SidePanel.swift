import SwiftUI

struct SidePanel: View {
    @Environment(AppState.self) private var state
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

            presetNote
                .padding(.top, 14)

            if !Compressor.isAvailable {
                toolsHint
                    .padding(.top, 8)
            }

            Spacer(minLength: 16)

            bottomSection
        }
        .padding(Layout.inset)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .shadow(color: theme.shadow, radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bonsai")
                    .font(.system(size: 16, weight: .bold))
                    .kerning(-0.2)
                    .foregroundStyle(theme.text)
                Text("PDF compressor")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
            }
            Spacer()
            ThemeToggle()
        }
    }

    private var presetNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Icon(name: "info-circle", size: 14)
                .foregroundStyle(theme.accent)
                .padding(.top, 1)
            Text(state.preset.summary)
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

    private var toolsHint: some View {
        HStack(alignment: .top, spacing: 9) {
            Icon(name: "bolt", size: 13)
                .foregroundStyle(theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("Bonsai compresses with two free command line tools. Install them with Homebrew, then reopen the app:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Toolchain.installCommand, forType: .string)
                } label: {
                    Text(Toolchain.installCommand)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .help("Copy the command, paste it in Terminal and reopen Bonsai")
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

    // MARK: Bottom

    @ViewBuilder
    private var bottomSection: some View {
        if let run = state.lastRun {
            SuccessCard(run: run)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !state.items.isEmpty {
                    saveModePicker
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if state.isCompressing && state.runTotal > 1 {
                    progressBar
                        .transition(.opacity)
                }
                compressButton
            }
        }
    }

    private var saveModePicker: some View {
        HStack(spacing: 6) {
            ForEach(SaveMode.allCases) { mode in
                let selected = state.saveMode == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.saveMode = mode }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.text : theme.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? theme.surface : .clear)
                                .shadow(color: theme.shadow.opacity(selected ? 0.8 : 0), radius: 3, y: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.help)
                .disabled(state.isCompressing)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.wellBG))
    }

    private var progressBar: some View {
        let fraction = Double(state.completedCount) / Double(max(1, state.runTotal))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.wellBG)
                Capsule().fill(theme.accentGradient)
                    .frame(width: max(6, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: fraction)
    }

    private var compressButton: some View {
        Button {
            state.compressAll()
        } label: {
            HStack(spacing: 9) {
                if state.isCompressing {
                    SpinnerRing(size: 16, line: 2)
                        .foregroundStyle(.white)
                    Text(state.runTotal > 1
                         ? "Compressing \(min(state.completedCount + 1, state.runTotal)) of \(state.runTotal)…"
                         : "Compressing…")
                        .contentTransition(.numericText())
                } else {
                    let count = state.pendingItems.count
                    Text(count > 1 ? "Compress \(count) PDFs" : "Compress PDF")
                        .contentTransition(.numericText())
                    Icon(name: "arrow-right", size: 15)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!state.canCompress)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.isCompressing)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.completedCount)
    }
}
