import AVFoundation
import MediaPlayer

// Owns AVPlayer observer lifetimes and bridges iOS media commands to the queue.
@MainActor
final class PlaybackSystem {
    private let player: AVPlayer
    private var tickToken: Any?
    private var transportToken: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var commands: [(MPRemoteCommand, Any)] = []

    init(model: PlaybackModel, player: AVPlayer) {
        self.player = player
        tickToken = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.tick() }
        }
        transportToken = player.observe(\.timeControlStatus, options: [.new]) { [weak model] _, _ in
            Task { @MainActor [weak model] in model?.transportChanged() }
        }

        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak model] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { model?.didEnd(item: item) }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak model] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { model?.playbackFailed(item: item) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak model] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { model?.interrupt(began: type == .began, shouldResume: options.contains(.shouldResume)) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak model] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { model?.pause() }
        })

        let remote = MPRemoteCommandCenter.shared()
        add(remote.playCommand, model: model) { model, _ in model.resume() }
        add(remote.pauseCommand, model: model) { model, _ in model.pause() }
        add(remote.togglePlayPauseCommand, model: model) { model, _ in model.toggle() }
        add(remote.nextTrackCommand, model: model) { model, _ in model.next() }
        add(remote.previousTrackCommand, model: model) { model, _ in model.previous() }
        add(remote.changePlaybackPositionCommand, model: model) { model, time in
            if let time { model.seek(to: time) }
        }
        updateCommands(model: model)
    }

    deinit {
        if let tickToken { player.removeTimeObserver(tickToken) }
        transportToken?.invalidate()
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in commands { command.removeTarget(target) }
    }

    func updateCommands(model: PlaybackModel) {
        let remote = MPRemoteCommandCenter.shared()
        let hasTrack = model.current != nil
        remote.playCommand.isEnabled = hasTrack
        remote.pauseCommand.isEnabled = hasTrack
        remote.togglePlayPauseCommand.isEnabled = hasTrack
        remote.nextTrackCommand.isEnabled = model.canAdvance
        remote.previousTrackCommand.isEnabled = hasTrack
        remote.changePlaybackPositionCommand.isEnabled = hasTrack && model.duration > 0
    }

    private func add(_ command: MPRemoteCommand, model: PlaybackModel,
                     action: @escaping @MainActor (PlaybackModel, Double?) -> Void) {
        let token = command.addTarget { [weak model] event in
            guard let model else { return .noActionableNowPlayingItem }
            let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            Task { @MainActor [weak model] in
                guard let model else { return }
                action(model, time)
            }
            return .success
        }
        commands.append((command, token))
    }
}
