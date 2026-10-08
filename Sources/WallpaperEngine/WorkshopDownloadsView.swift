import SteamLibrary
import SwiftUI

/// Workshop subscriptions that aren't wallpapers yet: queued, downloading or
/// refused by Steam. Each disappears once Steam installs it, and the
/// wallpaper appears in the library.
struct WorkshopDownloadsView: View {
    let sync: WorkshopSync

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    var body: some View {
        if sync.downloads.isEmpty {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Subscriptions Steam is downloading show up here until they’re ready.")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(sync.downloads) { item in
                        DownloadCard(item: item)
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}

private struct DownloadCard: View {
    let item: WorkshopSync.Download

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PreviewThumbnail(url: item.previewURL) }
                .clipped()
                .opacity(item.status == .unavailable ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title ?? "Workshop item \(item.id)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                status
            }
            .padding(10)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .contextMenu {
            Link("Open Workshop Page", destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")!)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .queued:
            HStack {
                Text("Queued")
                Spacer()
                if let size = item.size { Text(size.formattedBytes) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .downloading(let downloaded, let total):
            ProgressView(value: Double(downloaded), total: Double(max(total, 1))) {
                EmptyView()
            } currentValueLabel: {
                Text("\(downloaded.formattedBytes) of \(total.formattedBytes)")
            }
            .font(.caption)
        case .unavailable:
            Label("Unavailable on Steam", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Steam refused this item, usually because it was removed or made private.")
        }
    }
}

private extension UInt64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) }
}
