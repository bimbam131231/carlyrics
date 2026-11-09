import AVFoundation
import Foundation

/// Keeps the app alive in the background by looping silence through an
/// `AVAudioSession` (.playback + .mixWithOthers, so Spotify is never interrupted).
///
/// Reliability: restarts automatically after interruptions (calls, Siri,
/// navigation prompts), route changes (CarPlay / Bluetooth connect/disconnect)
/// and media-services resets. `ensurePlaying()` is also called as a watchdog.
@MainActor
final class KeepAliveAudio {
    var onLog: (String) -> Void = { _ in }

    private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in self?.handleInterruption(type) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue)" }.joined(separator: ",")
            Task { @MainActor in self?.handleRouteChange(reason, outputs: outputs) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onLog("Audio: media services reset")
                self.player = nil
                if self.isActive { self.activateAndPlay(reason: "media reset") }
            }
        })
    }

    func start() {
        isActive = true
        activateAndPlay(reason: "start")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        onLog("Audio: keep-alive stopped")
    }

    /// Watchdog: restart if something silently stopped the player.
    func ensurePlaying() {
        guard isActive else { return }
        if player?.isPlaying != true {
            activateAndPlay(reason: "watchdog")
        }
    }

    // MARK: - Private

    private func activateAndPlay(reason: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silentWAV())
                p.numberOfLoops = -1
                p.prepareToPlay()
                player = p
            }
            if player?.isPlaying != true { player?.play() }
            onLog("Audio: keep-alive playing (\(reason))")
        } catch {
            onLog("Audio: keep-alive failed (\(reason)): \(error.localizedDescription)")
            // Try again shortly (e.g. session still owned by a phone call).
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isActive, self.player?.isPlaying != true else { return }
                self.activateAndPlay(reason: "retry")
            }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            onLog("Audio: interruption began")
        case .ended:
            onLog("Audio: interruption ended")
            // Restart whether or not .shouldResume is set: we're silent and mixable.
            if isActive {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, self.isActive else { return }
                    self.activateAndPlay(reason: "after interruption")
                }
            }
        default:
            onLog("Audio: unknown interruption")
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?, outputs: String) {
        let name: String
        switch reason {
        case .newDeviceAvailable: name = "new device"
        case .oldDeviceUnavailable: name = "device removed"
        case .categoryChange: name = "category change"
        case .override: name = "override"
        case .routeConfigurationChange: name = "config change"
        default: name = "other"
        }
        // Category changes are often caused by our own setCategory: don't loop.
        guard reason != .categoryChange else { return }
        onLog("Audio: route change (\(name)) -> \(outputs)")
        if isActive { activateAndPlay(reason: "route change") }
    }

    /// 1 second of 16-bit mono silence as a WAV file.
    private static func silentWAV(seconds: Double = 1, sampleRate: Int = 22050) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        let dataSize = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                       // PCM
        u16(1)                       // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))  // byte rate
        u16(2)                       // block align
        u16(16)                      // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        d.append(Data(count: dataSize))
        return d
    }
}
