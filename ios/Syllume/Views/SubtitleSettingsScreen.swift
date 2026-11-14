import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SyllumeSettingsScreen: View {
    let subtitles: SubtitleController
    let navidrome: NavidromeConnection
    let youtube: PlatformConnection
    let library: LocalLibrary
    let player: PlaybackModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingServer = false
    @AppStorage("Folia.EnergySavingAnimation") private var energySaving = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { SubtitleSettingsContent(subtitles: subtitles) } label: {
                        SettingsDestination(title: "繁體字幕", symbol: "character.book.closed",
                                            detail: "內建 OpenCC，可離線轉換")
                    }
                    .accessibilityIdentifier("builtInTraditionalLyrics")
                    Toggle("省電動畫（30 fps）", isOn: $energySaving)
                } header: {
                    Text("字幕與動畫")
                } footer: {
                    Text("一般模式上限 60 fps；省電模式降低渲染解析度與繪光效果成本。系統低耗電模式也會自動採用省電動畫。")
                }
                Section("音樂來源") {
                    Button { showingServer = true } label: {
                        SettingsDestination(title: "Navidrome 設定", symbol: "server.rack")
                    }
                }
                Section {
                    NavigationLink {
                        DiagnosticsScreen(youtube: youtube, library: library, player: player, navidrome: navidrome)
                    } label: {
                        SettingsDestination(title: "開發者診斷", symbol: "waveform.path.ecg",
                                            detail: "檢查播放、音源與裝置")
                    }.accessibilityIdentifier("developerDiagnostics")
                } header: {
                    Text("維護")
                } footer: {
                    let info = Bundle.main.infoDictionary
                    Text("Syllume iOS \(info?["CFBundleShortVersionString"] as? String ?? "—") · build \(info?["CFBundleVersion"] as? String ?? "—")")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SyllumePalette.surface)
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .sheet(isPresented: $showingServer) { NavidromeSettings(connection: navidrome) }
        }
    }
}

private struct SettingsDestination: View {
    let title: String
    let symbol: String
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(SyllumePalette.accent)
                .frame(width: 34, height: 34)
                .background(SyllumePalette.accent.opacity(0.13), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
    }
}

struct SubtitleSettingsScreen: View {
    let subtitles: SubtitleController
    var embeddedInNavigation = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if embeddedInNavigation { settings }
        else { NavigationStack { settings } }
    }

    private var settings: some View {
        SubtitleSettingsContent(subtitles: subtitles)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }.accessibilityIdentifier("closeSubtitleSettings")
                }
            }
    }
}

private struct SubtitleSettingsContent: View {
    @Bindable var subtitles: SubtitleController
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportedReport = Data()
    @State private var neteaseDraft = ""
    @State private var showingReport = false
    var body: some View {
        Form {
            Section {
                Label("內建 · OpenCC 繁體字幕 v1.1.6", systemImage: "lock.fill")
                    .font(.subheadline)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("內建繁體字幕")
                    .accessibilityIdentifier("subtitleEngineState")
                    .accessibilityValue(subtitles.ready ? "已就緒" : "可離線轉換")
                Toggle("啟用內建模組", isOn: $subtitles.preferences.active)
                    .accessibilityIdentifier("subtitleActive")
                if !subtitles.ready && subtitles.engineError == nil { ProgressView("正在準備字幕搜尋") }
                if subtitles.engineError != nil {
                    Button("重新準備字幕搜尋") { subtitles.restartEngine(manual: true) }
                }
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
            Section("跨平台字幕來源") {
                Toggle("網易雲：原詞與中文翻譯", isOn: $subtitles.preferences.searchNetease)
                    .accessibilityIdentifier("subtitleNeteaseSource")
                Toggle("QQ 音樂：原詞與中文翻譯", isOn: $subtitles.preferences.searchQQ)
                    .accessibilityIdentifier("subtitleQQSource")
                Toggle("YouTube：已有人工中文字幕的影片", isOn: $subtitles.preferences.searchYouTube)
                    .accessibilityIdentifier("subtitleYouTubeSource")
                Text("預設啟用，無須填 Client ID 或 API 網址。搜尋順序為網易雲、QQ 音樂、YouTube，再檢查本機、Navidrome 與 LRCLIB。歌名與歌手會送至啟用的來源；音樂仍由目前來源播放。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("YouTube 會先篩選有字幕的影片，再檢查人工中文字幕軌，不做自動翻譯。壓在影片畫面內的字幕無法直接取用；不同版本必須通過原詞和時間軸核對。地區限制、登入或驗證要求可能使來源暫時不可用。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(["netease", "qq", "ytm"], id: \.self) { provider in
                    if let status = subtitles.sourceStatus[provider] {
                        LabeledContent(provider == "netease" ? "網易雲" : provider == "qq" ? "QQ 音樂" : "YouTube") {
                            Text(status).font(.caption).multilineTextAlignment(.trailing)
                        }
                    }
                }
                DisclosureGroup("進階：自訂網易雲來源（選填）") {
                    TextField("網易雲 API HTTPS 位址", text: $neteaseDraft)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !neteaseDraft.isEmpty, SubtitleNetwork.neteaseURL(neteaseDraft) == nil {
                        Text("請使用不含帳密、查詢參數的 HTTPS API 位址。").font(.caption).foregroundStyle(.orange)
                    }
                    Button("儲存字幕來源") {
                        subtitles.preferences.neteaseAPI = neteaseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .disabled(neteaseDraft == subtitles.preferences.neteaseAPI
                        || (!neteaseDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && SubtitleNetwork.neteaseURL(neteaseDraft) == nil))
                    Text("留空即使用內建直連。只有已有相容服務的維護者才需要更改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!subtitles.preferences.active)
            Section("完整診斷報告") {
                Toggle("顯示完整報告", isOn: $subtitles.preferences.reportVisible)
                if let error = subtitles.engineError { Text(error).foregroundStyle(.orange) }
                if subtitles.preferences.reportVisible {
                    Text(subtitles.reportText.split(separator: "\n").prefix(4).joined(separator: "\n"))
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("subtitleReport")
                    Button("查看完整診斷報告") { showingReport = true }
                }
                Button("複製診斷報告文字") {
                    UIPasteboard.general.string = subtitles.reportText
                    subtitles.notice = "已複製診斷報告文字。"
                }
                Button("匯出進階診斷（JSON）") {
                    exportedReport = subtitles.reportJSON; exporting = true
                }
                Text("查看、複製、匯出不會重新搜尋。報告僅在記憶體保存，不含帳號、憑證或整份歌詞。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SyllumePalette.surface)
        .navigationTitle("繁體字幕").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReport) {
            NavigationStack {
                ScrollView {
                    Text(subtitles.reportText).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .navigationTitle("完整診斷報告").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingReport = false } } }
            }
        }
        .onAppear { neteaseDraft = subtitles.preferences.neteaseAPI }
        .fileExporter(isPresented: $exporting, document: SyllumeReportDocument(data: exportedReport),
                      contentType: .json, defaultFilename: "Syllume-字幕診斷") { result in
            if case .failure = result { exportError = "未能儲存報告，可改用複製。" }
        }
        .alert("繁體字幕", isPresented: Binding(get: { subtitles.notice != nil || exportError != nil },
                                                set: { if !$0 { subtitles.notice = nil; exportError = nil } })) {
            Button("好", role: .cancel) { subtitles.notice = nil; exportError = nil }
        } message: { Text(exportError ?? subtitles.notice ?? "") }
    }
}

struct SyllumeReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
