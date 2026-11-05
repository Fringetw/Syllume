import SwiftUI

struct PlatformLibraryScreen: View {
    let connection: PlatformConnection
    let pauseLocalPlayback: () -> Void
    @State private var showingSettings = false
    @State private var loginTask: Task<Void, Never>?
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PlatformBrand(platform: connection.platform)
                Spacer()
                Button(connection.connected ? "帳號設定" : connection.platform == .youtube ? "連線說明" : "連接帳號") { showingSettings = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            if connection.connected {
                PlatformEntries(connection: connection, collection: .playlists, pauseLocalPlayback: pauseLocalPlayback)
                    .id(connection.sessionID)
            } else {
                ContentUnavailableView {
                    Label("連接你的曲庫", systemImage: "music.note.list")
                } description: {
                    Text(connection.platform == .spotify
                         ? "登入後瀏覽歌單與喜歡的歌曲，點歌曲可在 Spotify 開啟。首次連接需要開發者 Client ID。"
                         : "登入 Google 帳號即可讀取你的 YouTube 歌單與喜歡的影片，點選項目可在 YouTube Music 開啟。可取得內容依平台提供的範圍為準。")
                } actions: {
                    if connection.platform == .youtube {
                        Button(connection.connecting ? "正在登入…" : "連接 Google 帳號", action: connectGoogle)
                            .buttonStyle(.borderedProminent)
                            .disabled(!connection.googleConfiguration.isReady || connection.connecting)
                            .accessibilityIdentifier("googleConnect")
                        if let message = connection.googleConfiguration.userMessage {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("googleAvailability")
                        }
                        if let loginError { Text(loginError).font(.footnote).foregroundStyle(.orange) }
                    } else {
                        Button("設定並登入") { showingSettings = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) { PlatformAccountSettings(connection: connection) }
        .onDisappear { loginTask?.cancel(); connection.cancelLogin() }
    }

    private func connectGoogle() {
        guard loginTask == nil else { return }
        loginError = nil
        loginTask = Task {
            defer { loginTask = nil }
            do { try await connection.connectGoogle() }
            catch is CancellationError { }
            catch {
                if !Task.isCancelled { loginError = error.localizedDescription }
            }
        }
    }
}

private struct PlatformBrand: View {
    let platform: LibraryPlatform
    var body: some View {
        if platform == .spotify {
            Image("SpotifyLogo").resizable().scaledToFit().frame(width: 110, height: 34)
                .accessibilityLabel("Spotify")
        } else {
            Text(platform.title).font(.headline)
        }
    }
}

private struct PlatformEntries: View {
    let connection: PlatformConnection
    let collection: LibraryCollection
    let pauseLocalPlayback: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var entries: [LibraryEntry] = []
    @State private var cursor: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    private var isPlaylists: Bool { collection == .playlists }

    var body: some View {
        List {
            if !isPlaylists {
                Section {
                    PlatformBrand(platform: connection.platform)
                    Text("點選項目會在 \(connection.platform.title) 開啟。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if isPlaylists {
                Section {
                    NavigationLink {
                        PlatformEntries(connection: connection, collection: .liked, pauseLocalPlayback: pauseLocalPlayback)
                            .navigationTitle(connection.platform == .spotify ? "喜歡的歌曲" : "喜歡的影片")
                    } label: {
                        Label(connection.platform == .spotify ? "喜歡的歌曲" : "喜歡的影片（含音樂）", systemImage: "heart.fill")
                    }
                    if connection.platform == .youtube {
                        Text("這裡顯示 YouTube API 可讀取的帳號歌單與喜歡的影片，與 YouTube Music 的完整曲庫可能不同。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section(isPlaylists ? "我的歌單" : "歌曲") {
                ForEach(entries) { entry in
                    if isPlaylists {
                        NavigationLink {
                            PlatformEntries(connection: connection, collection: .playlist(entry.id), pauseLocalPlayback: pauseLocalPlayback)
                                .navigationTitle(entry.title)
                                .toolbar { ToolbarItem(placement: .primaryAction) { Button("在平台開啟") { open(entry.url) } } }
                        } label: { row(entry) }
                    } else {
                        Button { open(entry.url) } label: { row(entry) }
                            .accessibilityHint("在 \(connection.platform.title) 開啟")
                    }
                }
                if loaded && entries.isEmpty && error == nil { Text("這個帳號目前沒有可取得的項目。").foregroundStyle(.secondary) }
                if loading { ProgressView("正在讀取曲庫") }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Button("重試") { Task { await load(reset: !loaded) } }.disabled(loading)
                }
                if loaded && cursor != nil && error == nil {
                    Button("載入更多") { Task { await load(reset: false) } }.disabled(loading)
                }
            }
            Section {
                Button("在 \(connection.platform.title) 查看曲庫") { open(connection.platform.libraryURL) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isPlaylists ? .hidden : .visible, for: .navigationBar)
        .task(id: connection.sessionID) {
            requestID = UUID()
            entries = []
            cursor = nil
            loaded = false
            loading = false
            error = nil
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isPlaylists ? "music.note.list" : "arrow.up.right.square")
                .foregroundStyle(FoliaPalette.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 5)
    }

    private func open(_ url: URL) {
        pauseLocalPlayback()
        openURL(url)
    }

    private func load(reset: Bool) async {
        guard !loading, connection.connected else { return }
        let revision = connection.sessionID
        let ticket = UUID()
        requestID = ticket
        let previousCursor = reset ? nil : cursor
        loading = true
        error = nil
        defer { if requestID == ticket { loading = false } }
        do {
            let page = try await connection.page(collection, cursor: previousCursor)
            guard !Task.isCancelled, revision == connection.sessionID, requestID == ticket else { return }
            var seen = Set<String>()
            entries = ((reset ? [] : entries) + page.entries).filter { seen.insert($0.id).inserted }
            cursor = page.next == previousCursor ? nil : page.next
            loaded = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, revision == connection.sessionID, requestID == ticket else { return }
            self.error = (error as? PlatformError)?.errorDescription ?? "曲庫讀取失敗，請確認網路後重試。"
        }
    }
}

private struct PlatformAccountSettings: View {
    let connection: PlatformConnection
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var error: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var confirmDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlatformBrand(platform: connection.platform)
                    Text("連接後可在 Folia 瀏覽歌單與收藏，播放會交由原平台。")
                }
                if connection.platform == .spotify {
                    Section {
                        TextField("Client ID", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(connection.connecting || connection.connected)
                        Text("在 Spotify Dashboard 建立應用程式，選擇 iOS，並登記以下 Redirect URI。開發模式的應用程式擁有者需有 Premium，測試帳號須加入使用者名單。")
                        Text("folia-spotify://callback").font(.footnote.monospaced()).textSelection(.enabled)
                        Link("開啟 Spotify Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    } header: {
                        Text("開發者應用程式")
                    } footer: {
                        Text("Client ID 是應用程式識別碼。登入在平台官方的系統驗證視窗中完成；授權憑證存放於 iPhone 鑰匙圈。")
                    }
                } else {
                    Section("Google 帳號") {
                        Text("使用你自己的 Google 帳號登入並授權讀取 YouTube 歌單與喜歡的影片。登入設定由 App 提供者統一完成。")
                        if let message = connection.googleConfiguration.userMessage {
                            Text(message).foregroundStyle(.orange)
                            DisclosureGroup("提供給 App 提供者的版本資訊") {
                                Text(Bundle.main.bundleIdentifier ?? "無法取得安裝識別碼")
                                    .font(.footnote.monospaced()).textSelection(.enabled)
                                    .accessibilityIdentifier("installedBundleID")
                            }
                        }
                    }
                }
                Section {
                    if connection.connected {
                        Label("已連接", systemImage: "checkmark.circle.fill").foregroundStyle(FoliaPalette.accent)
                        Button("中斷連線", role: .destructive) { confirmDisconnect = true }
                    } else {
                        Button(connection.connecting ? "正在登入…" : connection.platform == .youtube ? "連接 Google 帳號" : "登入並讀取曲庫") {
                            error = nil
                            loginTask = Task {
                                do {
                                    if connection.platform == .youtube { try await connection.connectGoogle() }
                                    else { try await connection.connect(clientID: clientID) }
                                    if !Task.isCancelled { dismiss() }
                                } catch is CancellationError {
                                } catch { self.error = (error as? PlatformError)?.errorDescription ?? "登入未完成，請檢查網路與開發者設定。" }
                            }
                        }
                        .disabled(connection.connecting || (connection.platform == .youtube
                            ? !connection.googleConfiguration.isReady : clientID.isEmpty))
                    }
                    if let notice = error ?? connection.storageError { Text(notice).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(connection.platform.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .confirmationDialog("移除此裝置儲存的曲庫授權？", isPresented: $confirmDisconnect) {
                Button("中斷連線", role: .destructive) {
                    do { try connection.disconnect(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear { clientID = connection.clientID }
        .onDisappear { loginTask?.cancel(); connection.cancelLogin() }
    }
}
