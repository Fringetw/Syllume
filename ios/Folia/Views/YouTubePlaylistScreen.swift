import SwiftUI

struct YouTubePlaylistScreen: View {
    let connection: PlatformConnection
    let sync: YouTubePlaylistSync
    let play: ([Track], Int) -> Void
    @State private var showingPicker = false
    @State private var showingAccount = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YouTube 播放清單").font(.caption).foregroundStyle(.secondary)
                    Text(sync.cache.choice?.title ?? "尚未選擇清單").font(.headline)
                        .accessibilityIdentifier("selectedYouTubePlaylist")
                    if sync.cache.choice != nil {
                        #if DEBUG
                        Text("\(sync.cache.entries.count) 個項目 · \(sync.readyCount) 項已下載").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("playlistDownloadSummary")
                            .accessibilityValue("\(sync.readyCount)|\(sync.fixtureFileCount)")
                        #else
                        Text("\(sync.cache.entries.count) 個項目 · \(sync.readyCount) 項已下載").font(.caption).foregroundStyle(.secondary)
                        #endif
                    }
                }
                Spacer()
                Button("更換播放清單", systemImage: "list.bullet.rectangle") { showingPicker = true }
                    .labelStyle(.iconOnly).accessibilityIdentifier("changeYouTubePlaylist")
                    .frame(width: 44, height: 44)
                Button("帳號設定", systemImage: "person.crop.circle") { showingAccount = true }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            if sync.cache.choice == nil {
                ContentUnavailableView {
                    Label("選一份播放清單", systemImage: "music.note.list")
                } description: {
                    Text("選擇後會記住這份清單。歌曲取得完整音檔後，在 Folia 播放並顯示歌詞動畫。")
                } actions: {
                    Button("選擇播放清單") { showingPicker = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        if sync.refreshing { ProgressView("正在同步播放清單") }
                        if let date = sync.cache.syncedAt {
                            HStack { Text("上次同步"); Spacer(); Text(date, style: .relative).foregroundStyle(.secondary) }.font(.caption)
                        }
                        if let error = sync.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                        Button("立即同步", systemImage: "arrow.clockwise") { Task { await sync.synchronize(connection) } }
                            .disabled(sync.refreshing).accessibilityIdentifier("refreshYouTubePlaylist")
                    }
                    Section("歌曲") {
                        ForEach(sync.cache.entries) { entry in
                            let status = sync.status(for: entry)
                            Button {
                                if sync.track(for: entry) != nil { playEntry(entry) }
                                else { sync.retry(entry) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: sync.track(for: entry) == nil ? "arrow.down.circle" : "play.circle.fill")
                                        .foregroundStyle(FoliaPalette.accent).font(.title3).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                        Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                                        Text(status.label).font(.caption)
                                            .foregroundStyle(isFailure(status) ? .orange : .secondary)
                                    }
                                }.padding(.vertical, 5)
                            }
                            .accessibilityIdentifier("syncedTrack-" + entry.id)
                            .accessibilityHint(sync.track(for: entry) == nil ? "重新尋找可下載的完整音檔" : "使用 Folia 播放音樂檔")
                        }
                        if !sync.refreshing && sync.cache.entries.isEmpty {
                            Text("這份清單目前沒有可讀取的項目。").foregroundStyle(.secondary)
                        }
                    }
                    Section("下載") {
                        Toggle("自動下載", isOn: Binding(get: { sync.automatic }, set: { sync.automatic = $0 }))
                        Toggle("只在 Wi-Fi 下載", isOn: Binding(get: { sync.wifiOnly }, set: { sync.wifiOnly = $0 }))
                        Button("重試未下載項目") { sync.retryPending() }.disabled(!sync.automatic)
                        Text("只下載網易雲／QQ 音樂實際提供的完整版，依可取得的音質規格優先選擇。會員、授權或地區限制可能讓部分歌曲無法下載。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("音樂檔：檔案 → 我的 iPhone → Folia → Music。切換清單會保留既有檔案。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("開啟 App、回到前景及使用期間每 5 分鐘自動同步。回到 App 後會接續尚未下載的歌曲。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await sync.synchronize(connection) }
            }
        }
        .buttonStyle(FoliaPressStyle())
        .sheet(isPresented: $showingPicker) {
            YouTubePlaylistPicker(connection: connection, sync: sync) {
                showingPicker = false
                Task { await sync.synchronize(connection) }
            }
        }
        .sheet(isPresented: $showingAccount) { PlatformAccountSettings(connection: connection) }
        .onAppear { if sync.cache.choice == nil { showingPicker = true } }
    }

    private func isFailure(_ status: PlaylistDownloadStatus) -> Bool {
        if case .failed = status { return true }; return false
    }

    private func playEntry(_ entry: LibraryEntry) {
        let ready = sync.cache.entries.compactMap { row in sync.track(for: row).map { (row.id, $0) } }
        guard let index = ready.firstIndex(where: { $0.0 == entry.id }) else { return }
        play(ready.map(\.1), index)
    }
}

private struct YouTubePlaylistPicker: View {
    let connection: PlatformConnection
    let sync: YouTubePlaylistSync
    let selected: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingAccount = false
    @State private var loginTask: Task<Void, Never>?
    @State private var loginError: String?

    var body: some View {
        NavigationStack {
            Form {
                if connection.connected || sync.isFixture {
                    Section {
                        ForEach(sync.choices) { choice in
                            Button {
                                if sync.select(choice) { selected() }
                            } label: {
                                HStack {
                                    Label(choice.title, systemImage: choice.id == YouTubePlaylistChoice.liked.id ? "heart.fill" : "music.note.list")
                                    Spacer()
                                    if sync.cache.choice?.id == choice.id { Image(systemName: "checkmark") }
                                }.foregroundStyle(.primary)
                            }
                            .accessibilityIdentifier("playlistChoice-" + choice.id)
                        }
                        if sync.loadingChoices { ProgressView("正在讀取播放清單") }
                        if let error = sync.choiceError {
                            Text(error).foregroundStyle(.orange)
                            Button("重新讀取") { Task { await sync.loadChoices(connection) } }
                        }
                    } footer: {
                        Text("會記住最後選擇，下次自動載入。這裡列出 YouTube API 可讀取的帳號播放清單與喜歡的影片。")
                    }
                    Section {
                        Toggle("自動下載", isOn: Binding(get: { sync.automatic }, set: { sync.automatic = $0 }))
                        Toggle("只在 Wi-Fi 下載", isOn: Binding(get: { sync.wifiOnly }, set: { sync.wifiOnly = $0 }))
                        Text("音樂由網易雲／QQ 可提供的完整音檔取得，下載後交給 Folia 播放；不需要影片視窗。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = sync.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    }
                } else {
                    Section {
                        Text("先連接 Google 帳號，再選擇要同步的播放清單。")
                        Button(connection.connecting ? "正在登入…" : "連接 Google 帳號") {
                            guard loginTask == nil else { return }
                            loginError = nil
                            loginTask = Task {
                                defer { loginTask = nil }
                                do { try await connection.connectGoogle() }
                                catch is CancellationError { }
                                catch { loginError = error.localizedDescription }
                            }
                        }
                        .disabled(connection.connecting || !connection.googleConfiguration.isReady)
                        .accessibilityIdentifier("googleConnect")
                        if let message = connection.googleConfiguration.userMessage {
                            Text(message).foregroundStyle(.secondary).accessibilityIdentifier("googleAvailability")
                        }
                        if let loginError { Text(loginError).foregroundStyle(.orange) }
                        Button("連線說明") { showingAccount = true }
                    }
                }
            }
            .navigationTitle("選擇播放清單").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .task(id: connection.libraryIdentity) {
                sync.activate(connection.libraryIdentity)
                if connection.connected || sync.isFixture { await sync.loadChoices(connection) }
            }
            .sheet(isPresented: $showingAccount) { PlatformAccountSettings(connection: connection) }
        }
        .onDisappear { loginTask?.cancel(); connection.cancelLogin() }
    }
}
