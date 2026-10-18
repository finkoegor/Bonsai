import SwiftUI

struct FileGrid: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    let openPreview: (PDFItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 172, maximum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(state.items) { item in
                        FileCard(item: item, openPreview: openPreview)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.85).combined(with: .opacity),
                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                    addTile
                }
                .padding(Layout.inset)
                .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(state.items.count) \(state.items.count == 1 ? "file" : "files")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.items.count)
            Text(Format.size(state.listBytes))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(theme.text2)
            Spacer()
            Button {
                state.clearAll()
            } label: {
                HStack(spacing: 5) {
                    Icon(name: "trash-alt", size: 12)
                    Text("Clear all")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(state.isCompressing)
            .opacity(state.isCompressing ? 0.4 : 1)
        }
        .frame(height: Layout.headerHeight)
        .padding(.horizontal, Layout.inset)
        .padding(.top, Layout.inset)
        .padding(.bottom, 4)
    }

    private var addTile: some View {
        Button {
            BonsaiApp.openPanel(into: state)
        } label: {
            VStack(spacing: 10) {
                Icon(name: "plus", size: 22)
                Text("Add PDFs")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, minHeight: 208)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(theme.borderStrong)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.isCompressing)
        .modifier(HoverScale(scale: 1.02))
    }
}
