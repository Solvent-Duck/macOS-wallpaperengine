import AppKit
import SteamLibrary
import SwiftUI

/// What the library knows about a Workshop item, mildest to most complete.
enum WorkshopItemLocalState: Equatable {
    case notSubscribed
    case changing
    case subscribed
    case downloading(fraction: Double?)
    case inLibrary
}

@MainActor
func localState(of id: String, sync: WorkshopSync, library: GalleryViewModel) -> WorkshopItemLocalState {
    if library.wallpaper(inFolderNamed: id) != nil { return .inLibrary }
    if sync.pendingSubscriptionChanges.contains(id) { return .changing }
    if let download = sync.activeDownloads.first(where: { $0.id == id }) {
        if case .downloading(let done, let total) = download.status, total > 0 {
            return .downloading(fraction: Double(done) / Double(total))
        }
        return .downloading(fraction: nil)
    }
    return sync.subscribedIDs.contains(id) ? .subscribed : .notSubscribed
}

/// The Steam Workshop catalogue, browsed through the helper's Steam session.
/// The library's search field drives the query text.
struct WorkshopBrowseView: View {
    let sync: WorkshopSync
    @ObservedObject var library: GalleryViewModel
    let appModel: AppModel
    @State private var sort: WorkshopQuery.Sort = .trend
    @State private var type: String?
    @State private var tag: String?
    @State private var gridWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    private var query: WorkshopQuery {
        WorkshopQuery(sort: sort, text: library.searchText.trimmingCharacters(in: .whitespaces),
                      type: type, tag: tag, ratings: WorkshopSyncSettings.allowedRatings)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            results
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { sync.beginBrowsing() }
        .onDisappear { sync.endBrowsing() }
        .task(id: query) {
            // Wait for typing to settle before asking Steam.
            if sync.browse.query != query || (sync.browse.items.isEmpty && !sync.browse.isLoading) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                sync.search(query)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Sort", selection: $sort) {
                Text("Trending").tag(WorkshopQuery.Sort.trend)
                Text("Most Popular").tag(WorkshopQuery.Sort.popular)
                Text("Most Recent").tag(WorkshopQuery.Sort.recent)
                Text("Most Subscribed").tag(WorkshopQuery.Sort.subscribed)
            }
            .fixedSize()
            .disabled(!library.searchText.isEmpty)
            .help(library.searchText.isEmpty ? "Sort order" : "Search results are ordered by relevance")
            Picker("Type", selection: $type) {
                Text("All Types").tag(String?.none)
                ForEach(WorkshopCatalog.types, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            Picker("Genre", selection: $tag) {
                Text("All Genres").tag(String?.none)
                ForEach(WorkshopCatalog.genres, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            Spacer()
            if sync.browse.total > 0 {
                Text("\(sync.browse.total.formatted()) results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var results: some View {
        if case .problem(let problem) = sync.phase, !sync.isRunning, sync.browse.items.isEmpty {
            ContentUnavailableView {
                Label("Steam Workshop Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(workshopProblemMessage(problem))
            } actions: {
                Button("Try Again") { sync.search(query) }
                    .buttonStyle(.borderedProminent)
                Button("Steam Workshop Settings…") { appModel.openSettings(pane: .workshop) }
            }
        } else if let error = sync.browse.error, sync.browse.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load the Workshop", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { sync.search(query) }
            }
        } else if sync.browse.items.isEmpty {
            if sync.browse.isLoading || sync.browse.query != query {
                ProgressView("Loading the Workshop…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: library.searchText)
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(sync.browse.items) { item in
                        WorkshopBrowseCard(
                            item: item,
                            state: localState(of: item.id, sync: sync, library: library),
                            isSelected: library.selectedWorkshopID == item.id,
                            onSelect: {
                                library.selectedWorkshopID = item.id
                                gridFocused = true
                            },
                            onPrimaryAction: { primaryAction(for: item) }
                        )
                        .id(item.id)
                        .onAppear {
                            if item.id == sync.browse.items.last?.id { sync.loadMore() }
                        }
                    }
                }
                .padding(16)
                if sync.browse.isLoading {
                    ProgressView().padding(.bottom, 16)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
                handleKey(press.key, proxy: proxy)
            }
        }
    }

    /// Subscribe to an item not yet subscribed; apply one that is in the library.
    private func primaryAction(for item: WorkshopItem) {
        library.selectedWorkshopID = item.id
        switch localState(of: item.id, sync: sync, library: library) {
        case .notSubscribed:
            sync.subscribe(item.id)
        case .inLibrary:
            if let url = library.wallpaper(inFolderNamed: item.id)?.directoryURL {
                Task { await appModel.load(url) }
            }
        case .changing, .subscribed, .downloading:
            break
        }
    }

    private var columnCount: Int {
        max(1, Int((gridWidth - 32 + 16) / (190 + 16)))
    }

    private func handleKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = sync.browse.items.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        if key == .return {
            guard let id = library.selectedWorkshopID, let item = sync.browse.items.first(where: { $0.id == id }) else { return .ignored }
            primaryAction(for: item)
            return .handled
        }
        guard let current = library.selectedWorkshopID.flatMap(ids.firstIndex(of:)) else {
            library.selectedWorkshopID = ids[0]
            return .handled
        }
        let step = columnCount
        let target: Int
        switch key {
        case .leftArrow: target = current - 1
        case .rightArrow: target = current + 1
        case .upArrow: target = current - step
        case .downArrow: target = current + step
        default: return .ignored
        }
        let id = ids[min(max(target, 0), ids.count - 1)]
        library.selectedWorkshopID = id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
        return .handled
    }
}

private struct WorkshopBrowseCard: View {
    let item: WorkshopItem
    let state: WorkshopItemLocalState
    let isSelected: Bool
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PreviewThumbnail(url: item.previewURL) }
                .overlay(alignment: .topTrailing) { badge.padding(6) }
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let type = item.type { Text(type) }
                    if let rating = item.rating, rating != "Everyone" { Text("· \(rating)") }
                    Spacer()
                    if let score = item.approvalText { Label(score, systemImage: "hand.thumbsup") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2, perform: onPrimaryAction)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(state == .notSubscribed ? "Double-click to subscribe" : "")
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .notSubscribed:
            EmptyView()
        case .changing:
            ProgressView().controlSize(.small).padding(4).background(.regularMaterial, in: Capsule())
        case .subscribed:
            BadgeLabel(text: "Subscribed", icon: "checkmark")
        case .downloading(let fraction):
            BadgeLabel(text: fraction.map { "\(Int($0 * 100))%" } ?? "Queued", icon: "arrow.down")
        case .inLibrary:
            BadgeLabel(text: "In Library", icon: "checkmark.circle.fill")
        }
    }
}

private struct BadgeLabel: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }
}

/// Details and Subscribe for a Workshop item that isn't in the library yet.
struct WorkshopItemInspector: View {
    let item: WorkshopItem
    let sync: WorkshopSync
    @ObservedObject var library: GalleryViewModel
    @State private var confirmsUnsubscribe = false

    private var state: WorkshopItemLocalState { localState(of: item.id, sync: sync, library: library) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { PreviewThumbnail(url: item.previewURL) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text([item.type, item.rating].compactMap { $0 }.joined(separator: " · "))
                            Text("·")
                            Link("Workshop \(item.id)", destination: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")!)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    subscribeButton
                    if let error = sync.lastSubscriptionError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                if let approval = item.approvalText {
                    LabeledContent("Rating", value: "\(approval) of \((item.votesUp + item.votesDown).formatted()) votes")
                }
                LabeledContent("Subscribers", value: item.subscriptions.formatted())
                if item.fileSize > 0 {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
                }
                if item.timeUpdated.timeIntervalSince1970 > 0 {
                    LabeledContent("Updated", value: item.timeUpdated.formatted(date: .abbreviated, time: .omitted))
                }
                let genres = item.tags.filter { WorkshopCatalog.genres.contains($0) }
                if !genres.isEmpty {
                    LabeledContent("Tags", value: genres.joined(separator: ", "))
                }
            }
            let description = item.plainDescription
            if !description.isEmpty {
                Section("Description") {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Unsubscribe from “\(item.title)”?", isPresented: $confirmsUnsubscribe) {
            Button("Unsubscribe", role: .destructive) { sync.unsubscribe(item.id) }
        } message: {
            Text("Steam removes its downloaded files.")
        }
    }

    @ViewBuilder
    private var subscribeButton: some View {
        switch state {
        case .notSubscribed:
            Button {
                sync.subscribe(item.id)
            } label: {
                Label("Subscribe", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .changing:
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for Steam…") }
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(true)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction {
                    ProgressView(value: fraction) { Text("Downloading…") }
                } else {
                    ProgressView { Text("Waiting to download…") }
                }
            }
        case .subscribed, .inLibrary:
            Button(role: .destructive) {
                confirmsUnsubscribe = true
            } label: {
                Label("Unsubscribe", systemImage: "minus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }
}

extension WorkshopItem {
    /// Share of up-votes, once there are enough votes to mean something.
    var approvalText: String? {
        let total = votesUp + votesDown
        guard total >= 5 else { return nil }
        return "\(Int((Double(votesUp) / Double(total) * 100).rounded()))%"
    }

    /// The description without Steam's BBCode markup.
    var plainDescription: String {
        description
            .replacingOccurrences(of: #"\[/?[a-zA-Z0-9*]+(=[^\]]*)?\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func workshopProblemMessage(_ problem: WorkshopSync.Problem) -> String {
    switch problem {
    case .helperMissing: return "This build doesn’t include the Workshop helper. Rebuild with the Steamworks SDK in ~/sdk."
    case .sdkMissing: return "The Steamworks SDK wasn’t found. Choose its folder in Settings → Steam Workshop."
    case .steamNotRunning: return "Steam isn’t running. Open Steam and sign in, then try again."
    case .notOwned: return "The signed-in Steam account doesn’t own Wallpaper Engine."
    case .failed(let message): return message
    }
}
