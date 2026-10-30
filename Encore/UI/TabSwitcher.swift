import SwiftUI

struct TabSwitcher: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.tabs) { tab in
                        TabCard(tab: tab, isSelected: tab.id == store.selectedID) {
                            store.select(tab)
                            dismiss()
                        } onClose: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.close(tab) }
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(store.tabs.count == 1 ? "1 Tab" : "\(store.tabs.count) Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.newTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    if store.tabs.count > 1 {
                        Button("Close All", role: .destructive) {
                            store.closeAllTabs()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? Color.encoreAccent : Color.primary.opacity(0.08),
                                          lineWidth: isSelected ? 3 : 1)
                    )

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(8)
                }
            }

            HStack(spacing: 5) {
                if tab.isPlayingMedia {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.encoreAccent)
                }
                Text(tab.title.isEmpty ? (tab.url?.host ?? tab.pendingURL?.host ?? "New Tab") : tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var preview: some View {
        if let snapshot = tab.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ZStack {
                Color(.secondarySystemGroupedBackground)
                Image(systemName: "globe")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
