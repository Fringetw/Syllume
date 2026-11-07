import SwiftUI
import UniformTypeIdentifiers

// YouTube is a playlist source here; playback uses native audio and never creates a video view.
struct YouTubeMusicScreen: View {
    let connection: PlatformConnection
    let sync: YouTubeSyncController
    let library: LocalLibrary
    let account: NavidromeAccount?
    let play: (Track, [Track]) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPicker = false
    @State private var showingAccount = false
    @State private var attachment: SyncedYouTubeSong?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("YouTube 音樂").font(.headline)
                Spacer()
                Button("更換歌單") { showingPicker = true }
                    .disabled(!connection.connected).accessibilityIdentifier("changeYouTubePlaylist")
                Button(connection.connected ? "帳號" : "連接帳號") { showingAccount = true }
                    .accessibilityIdentifier("youtubeSyncAccount")
            }.buttonStyle(.bordered).padding(.horizontal, 22).padding(.vertical, 12)
            if !connection.connected {
                ContentUnavailableView {
                    Label("同步你的 YouTube 歌單", systemImage: "music.note.list")
                } description: {
                    Text("連接 Google 後選擇一份歌單，或「喜歡的影片」。之後會自動載入最後選擇，並尋找完整音源下載至本機播放。")
                } actions: { Button("連接 Google 帳號") { showingAccount = true }.buttonStyle(.borderedProminent) }
            } else if sync.snapshot.choice == nil {
                ContentUnavailableView {
                    Label("選擇要同步的歌單", systemImage: "music.note.list")
                } description: { Text("包含「喜歡的影片」，之後可隨時更換。") }
                actions: { Button("選擇歌單") { showingPicker = true }.buttonStyle(.borderedProminent) }
            } else {
                List {
                    Section {
                        Text(sync.snapshot.choice?.title ?? "").font(.title3.weight(.semibold))
                            .accessibilityIdentifier("selectedYouTubePlaylist")
                        Text("\(readyCount)／\(sync.snapshot.songs.count) 首可播放 · 純音訊")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let date = sync.snapshot.lastSync {
                            Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if sync.busy {
                                ProgressView().controlSize(.small)
                                Text(sync.phase).font(.footnote)
                                Spacer()
                                Button("停止") { sync.cancel() }
                            } else {
                                Button("同步並下載", systemImage: "arrow.triangle.2.circlepath") { refresh() }
                                    .accessibilityIdentifier("syncYouTubePlaylist")
                            }
                        }
                        if let error = sync.error { Text(error).foregroundStyle(.orange).font(.footnote) }
                    }
                    Section("歌曲") {
                        ForEach(sync.snapshot.songs) { song in
                            Button {
                                if let track = sync.localTrack(for: song, library: library) {
                                    let queue = sync.snapshot.songs.compactMap { sync.localTrack(for: $0, library: library) }
                                    play(track, queue)
                                } else { attachment = song; importing = true }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: sync.localTrack(for: song, library: library) == nil ? "arrow.down.circle" : "music.note")
                                        .foregroundStyle(FoliaPalette.accent).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(song.title).foregroundStyle(.primary).lineLimit(2)
                                        Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(status(song)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }.padding(.vertical, 5)
                            }
                            .contextMenu {
                                Button("附加音檔", systemImage: "folder.badge.plus") { attachment = song; importing = true }
                            }
                        }
                        if !sync.busy && sync.snapshot.songs.isEmpty { Text("這份歌單沒有可讀取的影片。").foregroundStyle(.secondary) }
                    }
                    Section {
                        Text("音檔存放於「檔案 → 我的 iPhone → Folia → YouTube Music」。自動選擇可取得的無損／較高音質完整音源；無法取得的歌曲可手動附加。")
                        Text("歌單在開啟此頁、回到 App 或下拉時同步。iOS 暫停 App 後，下次回來會接續未完成項目。")
                        if sync.snapshot.choice?.id == "liked" {
                            Text("YouTube 官方 API 最多提供最近 1,000 部喜歡的影片。")
                        }
                    }.font(.footnote).foregroundStyle(.secondary)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { refresh() }
            }
        }
        .sheet(isPresented: $showingAccount) { PlatformAccountSettings(connection: connection) }
        .sheet(isPresented: $showingPicker) {
            YouTubePlaylistPicker(connection: connection, current: sync.snapshot.choice) { choice in
                sync.choose(choice, connection: connection, library: library, account: account)
                showingPicker = false
            }
        }
        .task(id: connection.sessionID) {
            sync.activate(connection)
            if connection.connected {
                if sync.snapshot.choice == nil { showingPicker = true }
                else { refresh() }
            } else { showingPicker = false }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: account) { _, _ in sync.cancel(); refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            let song = attachment; attachment = nil
            guard let song else { return }
            if case .success(let url) = result {
                Task {
                    do { try await sync.attach(url, to: song, library: library); refresh() }
                    catch { message = "無法附加這個音檔，請確認檔案完整且可播放。" }
                }
            }
        }
        .alert("音檔", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private var readyCount: Int { sync.snapshot.songs.filter { sync.localTrack(for: $0, library: library) != nil }.count }
    private func refresh() { sync.synchronize(connection: connection, library: library, account: account) }
    private func status(_ song: SyncedYouTubeSong) -> String {
        if sync.localTrack(for: song, library: library) != nil { return sync.snapshot.bindings[song.videoID]?.quality ?? "已就緒" }
        return sync.statuses[song.videoID] ?? "尚未下載 · 點一下附加音檔"
    }
}

private struct YouTubePlaylistPicker: View {
    let connection: PlatformConnection
    let current: YouTubePlaylistChoice?
    let select: (YouTubePlaylistChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [YouTubePlaylistChoice] = [.liked]
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section("選擇自動同步的歌單") {
                    ForEach(choices) { choice in
                        Button { select(choice) } label: {
                            HStack {
                                Label(choice.title, systemImage: choice.id == "liked" ? "heart.fill" : "music.note.list")
                                Spacer()
                                if current?.id == choice.id { Image(systemName: "checkmark") }
                            }
                        }.accessibilityIdentifier("youtubePlaylist-" + choice.id)
                    }
                    if loading { ProgressView("正在載入歌單…") }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("YouTube 歌單").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .task(id: connection.sessionID) { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard !loading, connection.connected else { return }
        loading = true; error = nil
        defer { loading = false }
        let session = connection.sessionID
        do {
            var loaded: [YouTubePlaylistChoice] = [.liked], cursor: String?, cursors = Set<String>(), ids: Set<String> = ["liked"]
            repeat {
                let page = try await connection.page(.playlists, cursor: cursor)
                guard !Task.isCancelled, connection.sessionID == session else { return }
                loaded += page.entries.filter { ids.insert($0.id).inserted }.map { YouTubePlaylistChoice(id: $0.id, title: $0.title) }
                cursor = page.next
                if let cursor, !cursors.insert(cursor).inserted { throw PlatformError.message("歌單分頁回應重複，請重試。") }
            } while cursor != nil
            choices = loaded
        } catch is CancellationError { }
        catch { if connection.sessionID == session { self.error = "無法載入完整歌單，請下拉重試或重新連接 Google。" } }
    }
}
