import SwiftUI

/// Compact player bar above the toolbar for music playing in another tab.
/// Tap or swipe up to switch to that tab.
struct MiniPlayer: View {
    let title: String
    let subtitle: String
    let artwork: UIImage?
    let isPlaying: Bool
    var onOpen: () -> Void
    var onTogglePlay: () -> Void
    var onNext: () -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: artwork, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            Button(action: onNext) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height < -24 { onOpen() }
        })
    }
}

struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [.encoreAccent, .encoreAccentDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}
