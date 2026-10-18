import SwiftUI

/// Hosts the comparison in its own window. The item is looked up by id, so
/// removing it from the list closes the window.
struct PreviewWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID?

    var body: some View {
        if let item = state.items.first(where: { $0.id == itemID }) {
            ComparisonView(item: item)
                .navigationTitle(item.name)
        } else {
            Color.clear
                .frame(minWidth: 400, minHeight: 300)
                .background(theme.bg)
                .onAppear { dismiss() }
        }
    }
}
