import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FoliaSettingsScreen: View {
    let subtitles: SubtitleController
    let navidrome: NavidromeConnection
    @Environment(\.dismiss) private var dismiss
    @State private var showingServer = false
    var body: some View {
        NavigationStack {
            Form {
                Section("內建模組") {
                    NavigationLink { SubtitleSettingsContent(subtitles: subtitles) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("OpenCC 繁體字幕", systemImage: "character.book.closed")
                            Text("v1.1.6 · 隨 App 內建，可停用與調整")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("builtInTraditionalLyrics")
                }
                Section("音樂來源") {
                    Button("Navidrome 設定") { showingServer = true }
                }
                Section { Text("Folia iOS 0.3.1").foregroundStyle(.secondary) }
            }
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .sheet(isPresented: $showingServer) { NavidromeSettings(connection: navidrome) }
        }
    }
}

struct SubtitleSettingsScreen: View {
    let subtitles: SubtitleController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SubtitleSettingsContent(subtitles: subtitles)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
        }
    }
}

private struct SubtitleSettingsContent: View {
    @Bindable var subtitles: SubtitleController
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportedReport = Data()
    @State private var neteaseDraft = ""
    var body: some View {
        Form {
            Section {
                Label("內建 · OpenCC 繁體字幕 v1.1.6", systemImage: "lock.fill")
                    .font(.subheadline)
                Toggle("啟用內建模組", isOn: $subtitles.preferences.active)
                    .accessibilityIdentifier("subtitleActive")
            } footer: {
                Text("模組隨 App 內建。停用會還原原字幕，不會改寫歌詞檔。")
            }
            Section("簡轉繁") {
                Toggle("啟用簡轉繁", isOn: $subtitles.preferences.enabled).accessibilityIdentifier("subtitleConversion")
                Picker("繁體字形", selection: $subtitles.preferences.target) {
                    Text("臺灣繁體").tag("tw")
                    Text("OpenCC 標準繁體").tag("t")
                }
                Toggle("轉換原文歌詞與和聲", isOn: $subtitles.preferences.convertOriginal)
                Toggle("轉換中文譯文", isOn: $subtitles.preferences.convertTranslation)
                Toggle("保留含假名或韓文的原詞與譯文", isOn: $subtitles.preferences.protectJapanese)
                Text("純漢字日文無法自動辨識；日文歌可關閉原文轉換，只轉中文譯文。字典離線運作，不會將「軟件」改寫成「軟體」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!subtitles.preferences.active)
            Section("中文字幕搜尋") {
                Toggle("自動尋找中文字幕", isOn: $subtitles.preferences.autoSelectChinese)
                Toggle("字幕載入失敗時自動改用其他來源", isOn: $subtitles.preferences.fallbackOnFailure)
                Picker("字幕搜尋範圍", selection: $subtitles.preferences.searchDepth) {
                    Text("標準：每個來源最多 2 個版本").tag("standard")
                    Text("深入：每個來源最多 4 個版本").tag("deep")
                }
                Text("核對歌名、歌手、版本、時間軸與中文覆蓋率；保留可用的原文和逐字時間。完整度與格式檢查不代表譯意正確，也不會自行翻譯。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!subtitles.preferences.active)
            Section("字幕來源") {
                Label("本機附加歌詞、LRCLIB、已連接的 Navidrome", systemImage: "text.magnifyingglass")
                    .font(.subheadline)
                TextField("網易雲 API HTTPS 位址（選填）", text: $neteaseDraft)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !neteaseDraft.isEmpty, SubtitleNetwork.neteaseURL(neteaseDraft) == nil {
                    Text("請使用不含帳密、查詢參數的 HTTPS API 位址。").font(.caption).foregroundStyle(.orange)
                }
                Button("儲存字幕來源") {
                    subtitles.preferences.neteaseAPI = neteaseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .disabled(neteaseDraft == subtitles.preferences.neteaseAPI
                    || (!neteaseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && SubtitleNetwork.neteaseURL(neteaseDraft) == nil))
                Text("搜尋會將歌名與歌手送到上述可用來源。網易雲欄位可沿用桌面版管理者部署的相容 API；未設定便跳過，不影響離線簡轉繁。音樂仍由原來源播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("目前歌曲") {
                Button("切換繁體字幕") { subtitles.preferences.enabled.toggle() }
                Button("重新尋找中文字幕") { subtitles.command("retry") }
                Button("還原這首歌的原字幕") { subtitles.command("restore") }
                Button("查看字幕來源與中文覆蓋率") { subtitles.command("status") }
            }
            .disabled(!subtitles.preferences.active)
            Section("完整診斷報告") {
                Toggle("顯示完整報告", isOn: $subtitles.preferences.reportVisible)
                if let error = subtitles.engineError { Text(error).foregroundStyle(.orange) }
                if subtitles.preferences.reportVisible {
                    ScrollView([.horizontal, .vertical]) {
                        Text(subtitles.reportText).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("subtitleReport")
                    }
                    .frame(minHeight: 140, maxHeight: 300)
                }
                Button("複製完整診斷報告") {
                    UIPasteboard.general.string = subtitles.reportText
                    subtitles.notice = "已複製完整診斷報告。"
                }
                Button("下載完整診斷報告") {
                    exportedReport = subtitles.reportJSON; exporting = true
                }
                Text("查看、複製、匯出不會重新搜尋。報告僅在記憶體保存，不含帳號、憑證或整份歌詞。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("繁體字幕").navigationBarTitleDisplayMode(.inline)
        .onAppear { neteaseDraft = subtitles.preferences.neteaseAPI }
        .fileExporter(isPresented: $exporting, document: SubtitleReportDocument(data: exportedReport),
                      contentType: .json, defaultFilename: "Folia-字幕診斷") { result in
            if case .failure = result { exportError = "未能儲存報告，可改用複製。" }
        }
        .alert("繁體字幕", isPresented: Binding(get: { subtitles.notice != nil || exportError != nil },
                                                set: { if !$0 { subtitles.notice = nil; exportError = nil } })) {
            Button("好", role: .cancel) { subtitles.notice = nil; exportError = nil }
        } message: { Text(exportError ?? subtitles.notice ?? "") }
    }
}

private struct SubtitleReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
