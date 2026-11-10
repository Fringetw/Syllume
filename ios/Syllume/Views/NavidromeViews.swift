import SwiftUI

// Server configuration and cancelable search results.
struct NavidromeSearch: View {
    let account: NavidromeAccount?
    let configure: () -> Void
    let play: (Track, [Track], NavidromeClient) -> Void

    @State private var input = ""
    @State private var request: SearchRequest?
    @State private var results: [Track] = []
    @State private var completed: SearchRequest?
    @State private var error: String?
    @State private var loading = false

    private struct SearchRequest: Equatable {
        let query: String
        let id = UUID()
    }

    var body: some View {
        if let account {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("搜尋歌曲、歌手或專輯", text: $input)
                            .textFieldStyle(.roundedBorder).submitLabel(.search)
                            .onSubmit(submit)
                        Button("搜尋", action: submit).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if loading {
                        ProgressView("搜尋中")
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else if request == nil {
                        Text("從你的 Navidrome 音樂庫搜尋並串流。").foregroundStyle(.secondary)
                    } else if completed == request && results.isEmpty {
                        Text("沒有符合的歌曲。").foregroundStyle(.secondary)
                    } else if completed == request {
                        ForEach(results) { track in
                            TrackRow(track: track) { play(track, results, NavidromeClient(account: account)) }
                        }
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .task(id: request) {
                guard let request else { return }
                await search(request, account: account)
            }
            .onChange(of: account) { _, _ in
                request = nil
                results = []
                completed = nil
                error = nil
                loading = false
            }
        } else {
            ContentUnavailableView {
                Label("連接 Navidrome", systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text("輸入自己的 HTTPS 伺服器與帳號，即可搜尋和播放曲庫。")
            } actions: {
                Button("設定伺服器", action: configure).buttonStyle(.borderedProminent)
            }
        }
    }

    private func submit() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        error = nil
        loading = true
        request = SearchRequest(query: value)
    }

    private func search(_ current: SearchRequest, account: NavidromeAccount) async {
        do {
            let tracks = try await NavidromeClient(account: account).search(current.query)
            guard !Task.isCancelled, request == current else { return }
            results = tracks
            completed = current
        } catch {
            guard !Task.isCancelled, request == current else { return }
            self.error = (error as? NavidromeError)?.errorDescription ?? "搜尋失敗，請確認伺服器連線。"
        }
        loading = false
    }
}

struct NavidromeSettings: View {
    let connection: NavidromeConnection

    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("伺服器") {
                    TextField("https://music.example.com", text: $server)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("帳號", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密碼", text: $password).textContentType(.password)
                }
                .disabled(connecting)
                Section {
                    Button(connecting ? "測試連線中…" : "測試並儲存", action: connect)
                        .disabled(connecting || server.isEmpty || username.isEmpty || password.isEmpty)
                    if connection.account != nil {
                        Button("中斷連線", role: .destructive) {
                            do { try connection.disconnect(); dismiss() }
                            catch { self.error = NavidromeError.keychain.errorDescription }
                        }
                        .disabled(connecting)
                    }
                } footer: {
                    Text("密碼存放於 iPhone 的鑰匙圈。伺服器網址可包含部署子路徑。")
                }
                if let notice = error ?? connection.storageError { Section { Text(notice).foregroundStyle(.orange) } }
            }
            .navigationTitle("Navidrome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
        }
        .onAppear {
            server = connection.account?.server.absoluteString ?? ""
            username = connection.account?.username ?? ""
        }
        .onDisappear { connectionTask?.cancel() }
    }

    private func connect() {
        connecting = true
        error = nil
        connectionTask = Task {
            defer { connecting = false }
            do {
                try await connection.connect(server: server, username: username, password: password)
                if !Task.isCancelled { dismiss() }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? NavidromeError)?.errorDescription ?? "連不上 Navidrome，請檢查伺服器網址與連線。"
            }
        }
    }
}
