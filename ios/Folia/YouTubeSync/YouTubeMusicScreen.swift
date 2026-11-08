import SwiftUI
import UniformTypeIdentifiers

struct YouTubeMusicScreen: View {
    let connection: PlatformConnection
    let sync: YouTubeSyncController
    let library: LocalLibrary
    let account: NavidromeAccount?
    let player: PlaybackModel
    let openPlayer: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPicker = false
    @State private var showingAccount = false
    @State private var addingLocal = false
    @State private var attachment: SyncedYouTubeSong?
    @State private var downloadTarget: SyncedYouTubeSong?
    @State private var importing = false
    @State private var message: String?
    @State private var renaming = false
    @State private var name = ""
    @State private var query = ""
    @State private var editing: EditMode = .inactive

    private var songs: [SyncedYouTubeSong] { sync.snapshot.playlistSongs }
    private var filtered: [SyncedYouTubeSong] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? songs : songs.filter { $0.title.localizedStandardContains(text) || $0.artist.localizedStandardContains(text) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Folia 播放清單").font(.headline)
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
                    Text("連接 Google 後選擇一份歌單或「喜歡的影片」。Folia 會記住最後選擇，點歌時尋找可播放的音源。")
                } actions: { Button("連接 Google 帳號") { showingAccount = true }.buttonStyle(.borderedProminent) }
            } else if sync.snapshot.choice == nil {
                ContentUnavailableView {
                    Label("選擇要同步的歌單", systemImage: "music.note.list")
                } description: { Text("包含「喜歡的影片」，之後可隨時更換。") }
                actions: { Button("選擇歌單") { showingPicker = true }.buttonStyle(.borderedProminent) }
            } else { playlist }
        }
        .sheet(isPresented: $showingAccount, onDismiss: offerPlaylistPicker) { PlatformAccountSettings(connection: connection) }
        .sheet(isPresented: $showingPicker) {
            YouTubePlaylistPicker(connection: connection, current: sync.snapshot.choice,
                saved: (sync.snapshot.saved ?? [:]).values.map(\.choice).sorted { $0.title < $1.title }) { choice in
                    sync.choose(choice, connection: connection)
                    query = ""; editing = .inactive; showingPicker = false
                }
        }
        .sheet(isPresented: $addingLocal) {
            NavigationStack {
                List(library.tracks) { track in
                    Button {
                        sync.add(track); addingLocal = false
                    } label: { Label(track.title, systemImage: "music.note") }
                }.overlay {
                    if library.tracks.isEmpty { ContentUnavailableView("沒有本機音樂", systemImage: "music.note",
                        description: Text("先從本機曲庫匯入音檔。")) }
                }
                .navigationTitle("加入本機歌曲")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { addingLocal = false } } }
            }
        }
        .task(id: connection.sessionID) {
            sync.activate(connection)
            if connection.connected {
                if sync.snapshot.choice == nil { offerPlaylistPicker() }
                else { refresh() }
            } else { showingPicker = false }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            let song = attachment; attachment = nil
            guard let song else { return }
            if case .success(let url) = result {
                Task {
                    do { try await sync.attach(url, to: song, library: library) }
                    catch { message = "無法附加這個音檔，請確認檔案完整且可播放。" }
                }
            }
        }
        .alert("音檔", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .alert("重新命名 Folia 播放清單", isPresented: $renaming) {
            TextField("播放清單名稱", text: $name)
            Button("儲存") { sync.rename(name) }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("下載音樂到「檔案」？", isPresented: Binding(
            get: { downloadTarget != nil }, set: { if !$0 { downloadTarget = nil } }), presenting: downloadTarget) { song in
            Button("下載音樂") { sync.download(song, library: library, account: account, connection: connection); downloadTarget = nil }
        } message: { song in
            Text("「\(song.title)」會選擇可用的最高音質，必要時嘗試原 YouTube 音訊。音檔會先完整解碼驗證。")
        }
    }

    private var playlist: some View {
        List {
            Section {
                Text(sync.snapshot.playlistTitle).font(.title3.weight(.semibold))
                    .accessibilityIdentifier("selectedYouTubePlaylist")
                Text("\(songs.count) 首 · 點歌播放").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("播放", systemImage: "play.fill") {
                        if let first = songs.first { play(first, songs) }
                    }.disabled(songs.isEmpty)
                    Button("隨機", systemImage: "shuffle") {
                        let shuffled = songs.shuffled()
                        if let first = shuffled.first { play(first, shuffled) }
                    }.disabled(songs.isEmpty)
                    Spacer()
                    Menu("編輯", systemImage: "ellipsis.circle") {
                        Button("重新命名", systemImage: "pencil") { name = sync.snapshot.playlistTitle; renaming = true }
                        Button("加入本機歌曲", systemImage: "plus") { addingLocal = true }
                        Button(editing.isEditing ? "完成排序" : "調整順序", systemImage: "line.3.horizontal") {
                            query = ""; withAnimation { editing = editing.isEditing ? .inactive : .active }
                        }
                    }
                }.buttonStyle(.bordered)
                if let date = sync.snapshot.lastSync {
                    Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if sync.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(sync.phase).font(.footnote)
                        Spacer()
                        Button("停止同步") { sync.cancel() }.buttonStyle(.bordered)
                    }
                } else {
                    Button("同步歌單", systemImage: "arrow.triangle.2.circlepath") { refresh(force: true) }
                        .accessibilityIdentifier("syncYouTubePlaylist")
                }
                if sync.downloading != nil {
                    Button("取消下載", systemImage: "xmark.circle") { sync.cancelDownload() }
                }
                if let error = sync.error { Text(error).foregroundStyle(.orange).font(.footnote) }
            }
            Section("歌曲") {
                TextField("搜尋清單內的歌曲", text: $query).disabled(editing.isEditing)
                ForEach(filtered) { song in songRow(song) }
                    .onMove { offsets, destination in
                        guard query.isEmpty else { return }
                        var updated = songs; updated.move(fromOffsets: offsets, toOffset: destination); sync.reorder(updated)
                    }
                    .moveDisabled(!query.isEmpty)
                if !sync.busy && filtered.isEmpty { Text(songs.isEmpty ? "這份歌單尚無歌曲。" : "沒有符合的歌曲。").foregroundStyle(.secondary) }
            }
            Section {
                Text("長按歌曲可下載或附加音檔。下載位置：「檔案 → 我的 iPhone → Folia → YouTube Music」。")
                Text("編輯只影響 Folia。開啟此頁、回到 App 或下拉時會同步 YouTube 的變更。")
                if sync.snapshot.choice?.id == "liked" { Text("YouTube 官方 API 最多提供最近 1,000 部喜歡的影片。") }
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .environment(\.editMode, $editing)
        .listStyle(.plain).scrollContentBackground(.hidden)
        .refreshable { refresh(force: true) }
    }

    private func songRow(_ song: SyncedYouTubeSong) -> some View {
        Button { if !editing.isEditing { play(song, songs) } } label: {
            HStack(spacing: 12) {
                Group {
                    if let url = song.avatarURL {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                            placeholder: { Image(systemName: "person.crop.circle.fill") }
                    } else { Image(systemName: "music.note") }
                }
                .foregroundStyle(FoliaPalette.accent).frame(width: 32, height: 32).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).foregroundStyle(.primary).lineLimit(2)
                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(status(song)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("youtubeSong-" + song.id)
        .accessibilityValue(status(song))
        .contextMenu {
            Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(song, bindings: sync.snapshot.bindings, account: account, connection: connection)
            }
            if YouTubeVideo.validID(song.videoID) {
                Button("下載音樂", systemImage: "arrow.down.circle") { downloadTarget = song }.disabled(sync.downloading != nil)
                Button("附加音檔", systemImage: "folder.badge.plus") { attachment = song; importing = true }
            }
            Button("從清單移除", systemImage: "minus.circle", role: .destructive) { sync.remove(song) }
        }
    }

    private func play(_ song: SyncedYouTubeSong, _ queue: [SyncedYouTubeSong]) {
        player.playPlaylist(queue, from: song, bindings: sync.snapshot.bindings, account: account, connection: connection)
        openPlayer()
    }

    private func refresh(force: Bool = false) { sync.synchronize(connection: connection, force: force) }
    private func offerPlaylistPicker() {
        guard !showingAccount, connection.connected else { return }
        sync.activate(connection)
        if sync.snapshot.choice == nil { showingPicker = true }
    }
    private func status(_ song: SyncedYouTubeSong) -> String {
        if let status = sync.statuses[song.videoID] { return status }
        if sync.localTrack(for: song, library: library) != nil { return sync.snapshot.bindings[song.videoID]?.quality ?? "本機音檔" }
        return song.localTrackID == nil ? "點歌時搜尋音源" : "原本的本機檔案已移除"
    }
}

private struct YouTubePlaylistPicker: View {
    let connection: PlatformConnection
    let current: YouTubePlaylistChoice?
    let saved: [YouTubePlaylistChoice]
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
            .task(id: connection.sessionID) {
                choices = [.liked] + saved.filter { $0.id != "liked" }
                await load()
            }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard !loading, connection.connected else { return }
        loading = true; error = nil
        defer { loading = false }
        let session = connection.sessionID
        do {
            var loaded = [.liked] + saved.filter { $0.id != "liked" }, cursor: String?, cursors = Set<String>(), ids = Set(loaded.map(\.id))
            repeat {
                let page = try await connection.page(.playlists, cursor: cursor)
                guard !Task.isCancelled, connection.sessionID == session else { return }
                loaded += page.entries.filter { ids.insert($0.id).inserted }.map { YouTubePlaylistChoice(id: $0.id, title: $0.title) }
                cursor = page.next
                if let cursor, !cursors.insert(cursor).inserted { throw PlatformError.message("歌單分頁回應重複，請重試。") }
                choices = loaded
            } while cursor != nil
        } catch is CancellationError { }
        catch { if connection.sessionID == session { self.error = "無法載入完整歌單，請下拉重試或重新連接 Google。" } }
    }
}
