import SwiftUI
import UniformTypeIdentifiers

// Native music library, document picker and server entry point.
struct LibraryScreen: View {
    let library: LocalLibrary
    let player: PlaybackModel
    let navidrome: NavidromeConnection

    @State private var showingPlayer = false
    @State private var showingServer = false
    @State private var showingImporter = false
    @State private var lyricTarget: Track?
    @State private var deletionTarget: Track?
    @State private var message: String?
    @State private var query = ""
    @State private var source: Source = .local

    private enum Source: Hashable { case local, navidrome }
    private static let lyricTypes: [UTType] = [
        UTType(importedAs: "org.folia.lyrics.lrc"), UTType(importedAs: "org.folia.lyrics.fia")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                masthead
                Picker("音樂來源", selection: $source) {
                    Text("本機曲庫").tag(Source.local)
                    Text("Navidrome").tag(Source.navidrome)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

                switch source {
                case .local: localLibrary
                case .navidrome:
                    NavidromeSearch(account: navidrome.account, configure: { showingServer = true }) { track, tracks, client in
                        player.play(tracks, from: track, client: client)
                        showingPlayer = true
                    }
                }
            }
            .background(FoliaPalette.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let track = player.current {
                    MiniPlayer(track: track, player: player, open: { showingPlayer = true })
                }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) { NowPlayingScreen(player: player) }
        .sheet(isPresented: $showingServer) { NavidromeSettings(connection: navidrome) }
        .onChange(of: navidrome.account) { _, _ in player.clearNavidrome() }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: lyricTarget == nil ? [.audio] + Self.lyricTypes : Self.lyricTypes,
                      allowsMultipleSelection: lyricTarget == nil, onCompletion: handleImport)
        .alert("Folia", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("從本機曲庫移除歌曲？",
                            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
                            titleVisibility: .visible, presenting: deletionTarget) { track in
            Button("移除", role: .destructive) {
                do { try library.remove(track.id); player.removeFromQueue(track.id) }
                catch { message = "無法更新本機曲庫。" }
            }
        } message: { track in Text(track.title) }
    }

    private var masthead: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("L Y R I C S   R E I M A G I N E D")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FoliaPalette.accent)
                    .accessibilityHidden(true)
                Text("Folia").font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button { showingServer = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3).frame(width: 44, height: 44)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Navidrome 設定")
            Button {
                lyricTarget = nil
                showingImporter = true
            } label: {
                Image(systemName: "plus").font(.title3.weight(.medium))
                    .frame(width: 44, height: 44).background(FoliaPalette.accent, in: Circle())
                    .foregroundStyle(FoliaPalette.surface)
            }
            .accessibilityLabel("匯入音樂")
            .disabled(library.importInProgress)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var visibleTracks: [Track] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? library.tracks : library.tracks.filter {
            $0.title.localizedStandardContains(text) || $0.subtitle.localizedStandardContains(text)
        }
    }

    private var localLibrary: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                demoCard
                HStack {
                    Text("我的音樂").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if library.importInProgress { ProgressView().accessibilityLabel("正在匯入") }
                    else { Text("\(library.tracks.count) 首").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error = library.storageError { Text(error).foregroundStyle(.secondary) }
                if library.tracks.isEmpty {
                    Text("使用右上角 ＋ 從「檔案」匯入音樂。若有同名的 .lrc 或 .fia，選取音檔時可一起匯入。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    TextField("搜尋本機曲庫", text: $query)
                        .textFieldStyle(.roundedBorder).submitLabel(.search)
                    if visibleTracks.isEmpty { Text("沒有符合的歌曲。").foregroundStyle(.secondary) }
                    ForEach(visibleTracks) { track in
                        TrackRow(track: track, active: player.current?.source == .local && player.current?.id == track.id) {
                            player.play(visibleTracks, from: track)
                            showingPlayer = true
                        }
                        .contextMenu {
                            Button("附加歌詞", systemImage: "text.badge.plus") {
                                lyricTarget = track
                                showingImporter = true
                            }
                            Button("移除歌曲", systemImage: "trash", role: .destructive) { deletionTarget = track }
                        }
                    }
                }
            }
            .padding(22)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var demoCard: some View {
        Button {
            player.play([.demo], from: .demo)
            showingPlayer = true
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("F O L I A   S E S S I O N   /   0 1").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(FoliaPalette.accent)
                    Text("潮汐之間").font(.system(.title2, design: .serif, weight: .semibold))
                    Text("試聽 30 秒 · 同步歌詞").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .padding(18)
            .background {
                FoliaAtmosphere().clipShape(.rect(cornerRadius: 20))
            }
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10)) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("試聽潮汐之間，30 秒同步歌詞示範")
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let target = lyricTarget
        lyricTarget = nil
        switch result {
        case .success(let urls):
            if let target, let url = urls.first {
                Task {
                    do {
                        try await library.attachLyrics(url, to: target.id)
                        if let track = library.tracks.first(where: { $0.id == target.id }) { player.reloadLocalLyrics(track) }
                    } catch { message = "無法附加這份歌詞。請選取含時間軸的 LRC 或 Folia .fia 檔案。" }
                }
            } else {
                Task { if let warning = await library.importFiles(urls) { message = warning } }
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { message = "無法從「檔案」讀取選取的內容。" }
        }
    }
}

struct TrackRow: View {
    let track: Track
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: active ? "waveform" : "music.note")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(active ? FoliaPalette.accent : .secondary)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).foregroundStyle(active ? FoliaPalette.accent : .primary).lineLimit(2)
                    if !track.subtitle.isEmpty { Text(track.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let duration = track.duration, duration > 0 {
                    Text(playbackTime(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
