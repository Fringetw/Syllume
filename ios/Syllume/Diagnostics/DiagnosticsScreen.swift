import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DiagnosticsScreen: View {
    let youtube: PlatformConnection
    let library: LocalLibrary
    let player: PlaybackModel
    let navidrome: NavidromeConnection
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DiagnosticsEvents.enabledKey) private var enabled = true
    @AppStorage(DiagnosticsEvents.captureKey) private var capture = false
    @State private var session = DiagnosticsSession()
    @State private var selection = Set(DiagnosticArea.allCases)
    @State private var useCurrent = true
    @State private var allowMedia = false
    @State private var account = false
    @State private var exporting = false
    @State private var document: SyllumeReportDocument?
    @State private var exportName = "Syllume-Diagnostics"
    @State private var exportAfterReview = false
    @State private var copied = false
    @State private var exportType = UTType.json
    @State private var message: String?
    @State private var reviewing: DiagnosticReport?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            header
            settings
            if enabled {
                controls
                if session.running { progress }
                results
                history
            }
        }
        .scrollContentBackground(.hidden)
        .background(SyllumePalette.surface)
        .buttonStyle(SyllumePressStyle())
        .navigationTitle("開發者診斷")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                DiagnosticStagePreview(probe: session.stage).padding(.horizontal, 14)
                #if DEBUG
                if fixture, let report = session.report {
                    Text("測試報告內容").font(.system(size: 1)).frame(height: 1)
                        .accessibilityIdentifier("diagnosticsFixtureJSON")
                        .accessibilityValue((try? report.json()).map { String(decoding: $0, as: UTF8.self) } ?? "")
                }
                #endif
            }
        }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { session.stop(.appBackgrounded) } }
        .onChange(of: enabled) { _, value in
            if !value { session.stop(); capture = false; DiagnosticsEvents.shared.setCapture(false) }
        }
        .onChange(of: capture) { _, value in DiagnosticsEvents.shared.setCapture(enabled && value) }
        .sheet(isPresented: $account) { PlatformAccountSettings(connection: youtube) }
        .sheet(item: $reviewing, onDismiss: {
            if exportAfterReview { exportAfterReview = false; exporting = true }
        }) { report in
            NavigationStack {
                List {
                    reportActions(report)
                    resultSections(report.results)
                }.navigationTitle("診斷紀錄")
                    .toolbar { Button("關閉") { reviewing = nil } }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType,
                      defaultFilename: exportName) { outcome in
            if case .failure = outcome { message = "匯出失敗，請改選另一個檔案位置。" }
            document = nil
        }
        .alert("開發者診斷", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("刪除所有診斷紀錄？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("刪除紀錄", role: .destructive) { session.removeHistory() }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SyllumePalette.accent)
                    .frame(width: 44, height: 44)
                    .libraryControlSurface(in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("SYLLUME DIAGNOSTICS")
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        .foregroundStyle(SyllumePalette.accent)
                    Text("實機自動診斷").font(.system(.title2, design: .serif, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("報告保留在本機，可自行複製或匯出。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var settings: some View {
        Section {
            Toggle("啟用開發者診斷", isOn: $enabled)
                .accessibilityIdentifier("diagnosticsEnabled")
            if enabled {
                Toggle("記錄播放事件與系統摘要", isOn: $capture)
                    .accessibilityIdentifier("diagnosticsCapture")
                Text("重現 0:00 卡住之前先開啟紀錄。最多保留 96 筆不含歌名的事件，停用紀錄時會清空暫存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        Section("執行測試") {
            Button {
                run(Set(DiagnosticArea.allCases))
            } label: {
                Label("執行完整診斷", systemImage: "play.circle.fill").font(.headline)
            }
            .accessibilityIdentifier("diagnosticsRunAll").disabled(session.running)
            ForEach(DiagnosticArea.allCases) { area in
                Toggle(area.title, isOn: Binding(get: { selection.contains(area) }, set: { selected in
                    if selected { selection.insert(area) } else { selection.remove(area) }
                })).accessibilityIdentifier("diagnosticsArea-" + area.id)
            }
            .disabled(session.running)
            Button("執行所選項目", systemImage: "checklist") { run(selection) }
                .accessibilityIdentifier("diagnosticsRunSelected").disabled(selection.isEmpty || session.running)
            Toggle("優先測試目前的 YouTube 歌曲", isOn: $useCurrent).disabled(session.running)
            Toggle("測試我已獲授權音源的播放與下載", isOn: $allowMedia).disabled(session.running)
            Text("其餘情況用 HELP!! 進行配對。下載測試上限 15 MB，暫存檔於測試後移除。暫停主播放器可測音訊和動畫。")
                .font(.caption).foregroundStyle(.secondary)
            if !youtube.connected {
                Button("連接 Google 帳號", systemImage: "person.crop.circle") { account = true }.disabled(session.running)
            }
        }
    }

    private var progress: some View {
        Section("診斷進度") {
            ProgressView(value: Double(session.results.count), total: Double(max(1, session.plan.count))) {
                Text(session.stopReason != nil ? "正在停止…" : session.active?.title ?? "正在準備…")
            } currentValueLabel: {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(session.startedAt ?? timeline.date)))
                    Text("\(session.results.count)／\(session.plan.count) · \(seconds) 秒")
                        .monospacedDigit().font(.footnote).foregroundStyle(.secondary)
                }
            }.tint(SyllumePalette.accent).accessibilityIdentifier("diagnosticsProgress")
            Button("取消診斷", role: .cancel) { session.stop() }
                .accessibilityIdentifier("diagnosticsCancel").disabled(session.stopReason != nil)
        }
    }

    @ViewBuilder private var results: some View {
        if let report = session.report {
            Section("本次報告") {
                if let stopped = report.stopReason { Label(stopped.title, systemImage: "pause.circle") }
                Text("已記錄 \(report.results.count) 個類別").accessibilityIdentifier("diagnosticsCompleted")
                reportActions(report)
                let retry = report.retryAreas
                Button("重試未通過項目", systemImage: "arrow.clockwise") { run(retry) }.disabled(retry.isEmpty)
            }
            resultSections(report.results)
        } else if session.running {
            resultSections(session.results)
        }
    }

    @ViewBuilder private var history: some View {
        Section("最近診斷") {
            if session.storageIssue { Text("無法讀取或儲存診斷紀錄。").font(.footnote).foregroundStyle(.orange) }
            if session.history.isEmpty {
                Text("完成後會保留最近 5 份報告。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(session.history) { report in
                Button { reviewing = report } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(report.appVersion) · build \(report.build) · \(report.results.count) 個類別")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("diagnosticsHistory").disabled(session.running)
            }
            if !session.history.isEmpty {
                Button("清除診斷紀錄", role: .destructive) { confirmRemove = true }.disabled(session.running)
            }
        }
    }

    private func resultSections(_ results: [DiagnosticResult]) -> some View {
        ForEach(results) { result in
            Section(result.area.title) {
                DisclosureGroup {
                    ForEach(result.checks) { DiagnosticCheckRow(check: $0) }
                } label: {
                    HStack {
                        DiagnosticBadge(state: result.state)
                        Spacer()
                        Text(result.timeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("diagnosticsResult-" + result.id)
            }
        }
    }

    @ViewBuilder private func reportActions(_ report: DiagnosticReport) -> some View {
        Button(copied ? "已複製診斷報告" : "複製診斷報告", systemImage: "doc.on.doc") {
            UIPasteboard.general.setItems([["public.utf8-plain-text": report.text]], options: [
                .localOnly: true, .expirationDate: Date().addingTimeInterval(3600)
            ])
            copied = true
        }.accessibilityIdentifier("diagnosticsCopy")
        Button("匯出 JSON", systemImage: "arrow.up.document") { export(report, as: .json) }
            .accessibilityIdentifier("diagnosticsExportJSON")
        Button("匯出純文字", systemImage: "doc.plaintext") { export(report, as: .plainText) }
    }

    private func export(_ report: DiagnosticReport, as type: UTType) {
        do {
            document = SyllumeReportDocument(data: type == .json ? try report.json() : Data(report.text.utf8))
            exportType = type
            exportName = "Syllume-Diagnostics-\(report.appVersion)-\(Int(report.startedAt.timeIntervalSince1970))"
            if reviewing != nil { exportAfterReview = true; reviewing = nil }
            else { exporting = true }
        } catch { message = "無法建立診斷報告。" }
    }

    private func run(_ areas: Set<DiagnosticArea>) {
        copied = false
        session.start(areas, inputs: DiagnosticsInputs(youtube: youtube, library: library, player: player,
            navidrome: navidrome.account, useCurrentSong: useCurrent, allowMedia: allowMedia, fixture: fixture))
    }

    private var fixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--diagnostics-ui-fixture")
        #else
        false
        #endif
    }
}

private struct DiagnosticBadge: View {
    let state: DiagnosticState

    var body: some View {
        let style: (String, Color) = switch state {
        case .passed: ("checkmark.circle.fill", SyllumePalette.accent)
        case .failed: ("xmark.octagon.fill", .red)
        case .partial: ("circle.lefthalf.filled", .orange)
        case .unverifiable: ("minus.circle", .secondary)
        }
        Label(state.title, systemImage: style.0)
            .foregroundStyle(style.1)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(style.1.opacity(0.12), in: Capsule())
    }
}

private struct DiagnosticCheckRow: View {
    let check: DiagnosticCheck

    var body: some View {
        DisclosureGroup {
            Text("\(check.evidence.title) · \(check.timeLabel)").foregroundStyle(.secondary)
            if let problem = check.problem {
                Text(problem.detail)
                Text(check.checkpoints.joined(separator: " → ")).foregroundStyle(.secondary)
            }
            if let note = check.note { Text(note).foregroundStyle(.secondary) }
            ForEach(check.metrics.keys.sorted(), id: \.self) { key in
                if let value = check.metrics[key] {
                    LabeledContent(key, value: value.formatted(.number.precision(.fractionLength(0...3))))
                        .monospacedDigit()
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                DiagnosticBadge(state: check.state)
            }
        }.font(.footnote)
    }
}
