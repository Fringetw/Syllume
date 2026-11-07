import SwiftUI

// All lyric discovery is in one sheet; conversion preferences remain under Settings.
struct LyricSearchScreen: View {
    let subtitles: SubtitleController
    @State var title: String
    @State var artist: String
    let choose: (LyricSearchRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [LyricSearchRecord] = []
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var showingPreferences = false

    var body: some View {
        NavigationStack {
            Form {
                Section("目前歌曲的中文字幕") {
                    Button("尋找中文字幕") { subtitles.command("retry") }
                        .accessibilityIdentifier("findChineseLyrics")
                        .disabled(!subtitles.preferences.active)
                    Text("依序搜尋已啟用的網易雲、QQ 音樂與 YouTube 來源，核對版本和時間後補上中文。來源開關在「設定 → 繁體字幕」。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(["netease", "qq", "ytm"], id: \.self) { provider in
                        if let status = subtitles.sourceStatus[provider] {
                            LabeledContent(provider == "netease" ? "網易雲" : provider == "qq" ? "QQ 音樂" : "YouTube", value: status)
                                .font(.caption)
                        }
                    }
                    Button("查看字幕來源與中文覆蓋率") { subtitles.command("status") }
                    Button("還原這首歌的原字幕") { subtitles.command("restore") }
                }
                Section("尋找其他同步歌詞版本") {
                    TextField("歌名", text: $title)
                    TextField("歌手", text: $artist)
                    Button(loading ? "正在尋找…" : "搜尋 LRCLIB") { search() }.disabled(loading || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                Section("選擇與目前音訊相同的版本") {
                    ForEach(records) { record in
                        Button { choose(record); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.trackName).foregroundStyle(.primary)
                                Text("\(record.artistName) · \(record.albumName) · \(playbackTime(record.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(record.syncedLyrics?.split(separator: "\n").prefix(2).joined(separator: "\n") ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("尋找歌詞").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() }.accessibilityIdentifier("closeLyricSearch") } }
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { showingPreferences = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("繁體字幕設定")
            } }
            .buttonStyle(FoliaPressStyle())
        }
        .onDisappear { task?.cancel() }
        .onChange(of: title) { _, _ in cancelSearch() }
        .onChange(of: artist) { _, _ in cancelSearch() }
        .sheet(isPresented: $showingPreferences) { SubtitleSettingsScreen(subtitles: subtitles) }
        .alert("歌詞", isPresented: Binding(get: { subtitles.notice != nil }, set: { if !$0 { subtitles.notice = nil } })) {
            Button("好", role: .cancel) { subtitles.notice = nil }
        } message: { Text(subtitles.notice ?? "") }
    }
    private func cancelSearch() { task?.cancel(); loading = false; records = []; error = nil }
    private func search() {
        task?.cancel(); loading = true; error = nil; records = []
        let title = title, artist = artist
        task = Task {
            do {
                let found = try await OnlineLyrics.shared.search(title: title, artist: artist)
                guard !Task.isCancelled else { return }
                records = found; loading = false
                if found.isEmpty { error = "找不到同步歌詞，可調整歌名或歌手，或附加自己的 LRC／FIA。" }
            } catch {
                guard !Task.isCancelled else { return }
                loading = false; self.error = "歌詞服務未回應，請稍後再試。"
            }
        }
    }
}
