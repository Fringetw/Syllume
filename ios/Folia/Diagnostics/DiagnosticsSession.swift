import Darwin
import Foundation
import MetricKit
import Network
import Observation
import UIKit

@MainActor
final class DiagnosticsEvents {
    static let shared = DiagnosticsEvents()
    nonisolated static let enabledKey = "Folia.Diagnostics.Enabled"
    nonisolated static let captureKey = "Folia.Diagnostics.Capture"
    private var entries: [DiagnosticEvent] = []
    private var advancingSince: TimeInterval?
    private var advancingSeconds: TimeInterval = 0
    private var appInitialization: TimeInterval?
    private(set) var firstViewMs: Double?
    private(set) var capturing = UserDefaults.standard.bool(forKey: captureKey)
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func beganInitialization() {
        if appInitialization == nil { appInitialization = ProcessInfo.processInfo.systemUptime }
    }

    func firstViewAppeared() {
        guard firstViewMs == nil, let appInitialization else { return }
        firstViewMs = (ProcessInfo.processInfo.systemUptime - appInitialization) * 1000
        setCapture(enabled && capturing)
    }

    func setCapture(_ value: Bool) {
        capturing = value
        UserDefaults.standard.set(value, forKey: Self.captureKey)
        DiagnosticsSystemMetrics.shared.setEnabled(value)
        if !value { clear() }
    }

    func record(_ kind: DiagnosticEventKind, source: DiagnosticSource? = nil, problem: DiagnosticProblem? = nil,
                since: Date? = nil, elapsedMs: Int? = nil) {
        guard capturing else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .playbackStarted: if advancingSince == nil { advancingSince = uptime }
        case .playbackPaused, .playbackStalled, .audioInterruption, .lookupStarted:
            if let advancingSince { advancingSeconds += max(0, uptime - advancingSince) }
            advancingSince = nil
        default: break
        }
        entries.append(DiagnosticEvent(at: now, kind: kind, source: source, problem: problem,
            elapsedMs: elapsedMs ?? since.map { max(0, Int(now.timeIntervalSince($0) * 1000)) }))
        entries.removeFirst(max(0, entries.count - 96))
    }

    var snapshot: [DiagnosticEvent] { entries }
    var observedPlaybackSeconds: TimeInterval {
        advancingSeconds + (advancingSince.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0)
    }

    func clear() { entries.removeAll(); advancingSince = nil; advancingSeconds = 0 }
}

@MainActor
final class DiagnosticsSystemMetrics: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsSystemMetrics()
    private var enabled = false
    private(set) var metrics: [String: Double] = [:]
    private(set) var diagnosticFrames: [DiagnosticSystemTrace] = []

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { MXMetricManager.shared.add(self) }
        else { MXMetricManager.shared.remove(self); metrics = [:]; diagnosticFrames = [] }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        guard let payload = payloads.last else { return }
        let result = [
            "metricKit_launchHistogramBuckets": payload.applicationLaunchMetrics.map { Double($0.histogrammedTimeToFirstDraw.totalBucketCount) },
            "metricKit_reportHours": payload.timeStampEnd.timeIntervalSince(payload.timeStampBegin) / 3600
        ].compactMapValues { $0 }
        Task { @MainActor [weak self] in
            if let self, enabled { metrics.merge(result) { _, latest in latest } }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var result: [String: Double] = [:]
        var traces: [DiagnosticSystemTrace] = []
        for payload in payloads.suffix(3) {
            let crashes = payload.crashDiagnostics ?? []
            let hangs = payload.hangDiagnostics ?? []
            result["metricKit_crashes", default: 0] += Double(crashes.count)
            result["metricKit_hangs", default: 0] += Double(hangs.count)
            for crash in crashes.prefix(2) {
                let offsets = DiagnosticSystemTrace.foliaOffsets(crash.callStackTree.jsonRepresentation())
                if !offsets.isEmpty { traces.append(DiagnosticSystemTrace(kind: .crash, foliaOffsets: offsets)) }
            }
            for hang in hangs.prefix(2) {
                let offsets = DiagnosticSystemTrace.foliaOffsets(hang.callStackTree.jsonRepresentation())
                if !offsets.isEmpty { traces.append(DiagnosticSystemTrace(kind: .hang, foliaOffsets: offsets)) }
            }
        }
        let snapshot = result, frameSnapshot = traces
        Task { @MainActor [weak self] in
            if let self, enabled {
                metrics.merge(snapshot) { _, latest in latest }
                diagnosticFrames = Array((diagnosticFrames + frameSnapshot).suffix(6))
            }
        }
    }
}

enum DiagnosticsDevice {
    static func network() async -> DiagnosticNetwork {
        let (values, continuation) = AsyncStream<DiagnosticNetwork>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let result: DiagnosticNetwork
            if path.status == .unsatisfied { result = .offline }
            else if path.status != .satisfied { result = .unknown }
            else if path.usesInterfaceType(.wifi) { result = .wifi }
            else if path.usesInterfaceType(.cellular) { result = .cellular }
            else if path.usesInterfaceType(.wiredEthernet) { result = .wired }
            else { result = .other }
            continuation.yield(result); continuation.finish()
        }
        monitor.start(queue: DispatchQueue(label: "Folia.Diagnostics.Network"))
        defer { monitor.cancel(); continuation.finish() }
        return (try? await PlaybackLookup.within(.seconds(1)) {
            var iterator = values.makeAsyncIterator()
            return await iterator.next() ?? .unknown
        }) ?? .unknown
    }

    static var model: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPhone Simulator"
        #else
        var info = utsname()
        guard uname(&info) == 0 else { return "iPhone" }
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }

    static func counters() -> [String: Double] {
        var counters: [String: Double] = [:]
        var cpu = timespec()
        if clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu) == 0 {
            counters["appCPU_s"] = Double(cpu.tv_sec) + Double(cpu.tv_nsec) / 1_000_000_000
        }
        var memory = mach_task_basic_info()
        var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size)
            }
        }
        if result == KERN_SUCCESS { counters["appResidentMemory_MiB"] = Double(memory.resident_size) / 1_048_576 }
        return counters
    }
}

@MainActor
struct DiagnosticsInputs {
    let youtube: PlatformConnection
    let library: LocalLibrary
    let player: PlaybackModel
    let navidrome: NavidromeAccount?
    let useCurrentSong: Bool
    let allowMedia: Bool
    let fixture: Bool
}

@MainActor @Observable
final class DiagnosticsSession {
    private(set) var history: [DiagnosticReport] = []
    private(set) var results: [DiagnosticResult] = []
    private(set) var active: DiagnosticArea?
    private(set) var plan: [DiagnosticArea] = []
    private(set) var startedAt: Date?
    private(set) var report: DiagnosticReport?
    private(set) var storageIssue = false
    private(set) var stopReason: DiagnosticCode?
    let stage = DiagnosticStageProbe()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let file: URL

    var running: Bool { startedAt != nil }

    init() {
        let folder: String
        #if DEBUG
        folder = ProcessInfo.processInfo.arguments.contains("--diagnostics-ui-fixture") ? "DiagnosticsFixture" : "Diagnostics"
        #else
        folder = "Diagnostics"
        #endif
        file = URL.applicationSupportDirectory.appending(path: "Folia/\(folder)/reports.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 4_000_000 else { throw CocoaError(.fileReadTooLarge) }
                history = Array(try JSONDecoder().decode([DiagnosticReport].self, from: data).prefix(5))
                report = history.first
            } catch { storageIssue = true }
        }
    }

    func start(_ areas: Set<DiagnosticArea>, inputs: DiagnosticsInputs) {
        guard task == nil, !areas.isEmpty, DiagnosticsEvents.shared.enabled else { return }
        let start = Date()
        plan = DiagnosticArea.allCases.filter(areas.contains)
        startedAt = start; report = nil; results = []; stopReason = nil
        let before = DiagnosticsDevice.counters()
        task = Task { [weak self] in
            guard let self else { return }
            let network = inputs.fixture ? DiagnosticNetwork.unknown : await DiagnosticsDevice.network()
            let probes = DiagnosticProbes(inputs: inputs)
            for area in plan {
                guard !Task.isCancelled else { break }
                active = area
                let began = Date()
                let checks: [DiagnosticCheck]
                switch area {
                case .google: checks = await probes.google()
                case .captions: checks = await probes.captions()
                case .audio: checks = await probes.audio()
                case .animation: checks = await probes.animation(stage)
                case .device: checks = probes.device(since: start, counters: before)
                }
                if Task.isCancelled { break }
                results.append(DiagnosticResult(area: area, checks: checks, since: began))
            }
            let stopped = stopReason
            let pending = DiagnosticArea.allCases.filter { area in !results.contains { $0.area == area } }
            let unverified = results.flatMap(\.checks).filter { $0.state != .passed }.map(\.title)
            let info = Bundle.main.infoDictionary
            let environment: DiagnosticEnvironment
            #if targetEnvironment(simulator)
            environment = inputs.fixture ? .ciFixture : .simulator
            #else
            environment = .iphone
            #endif
            let ready = DiagnosticReport(schemaVersion: 1, id: UUID(), appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info?["CFBundleVersion"] as? String ?? "unknown", operatingSystem: UIDevice.current.systemVersion,
                deviceModel: DiagnosticsDevice.model, environment: environment, startedAt: start, endedAt: Date(),
                connection: network, stopReason: stopped, requestedAreas: plan, results: results, events: DiagnosticsEvents.shared.snapshot,
                systemTraces: DiagnosticsSystemMetrics.shared.diagnosticFrames,
                reproduction: [
                    "YouTube → 選擇歌單 → 點播放。若停在 0:00，等到出現音源訊息後關閉播放頁。",
                    "設定 → 開發者診斷 → 執行完整診斷。若希望保留 0:00 前後的階段，請先開啟播放事件紀錄再重現。",
                    "字幕案例：JANE DOE（RCXjG2tsojs）。音源案例：目前的 YouTube 歌曲，或 HELP!!（公開曲目）。"
                ], notCovered: pending.map(\.title) + unverified)
            stage.reset()
            active = nil; startedAt = nil; task = nil
            report = ready
            history = Array(([ready] + history).prefix(5))
            persist()
        }
    }

    func stop(_ reason: DiagnosticCode = .cancelled) {
        guard running else { return }
        stopReason = stopReason ?? reason
        task?.cancel()
    }

    func removeHistory() {
        guard !running else { return }
        history = []; report = nil
        DiagnosticsEvents.shared.clear()
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            storageIssue = false
        } catch { storageIssue = true }
    }

    private func persist() {
        do {
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            try JSONEncoder().encode(history).write(to: file, options: [.atomic, .completeFileProtection])
            storageIssue = false
        } catch { storageIssue = true }
    }
}
