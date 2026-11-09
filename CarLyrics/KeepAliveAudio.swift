import AVFoundation
import Foundation

/// Keeps the app alive in the background by looping near-silence through an
/// `AVAudioSession` (.playback + .mixWithOthers, so Spotify is never interrupted).
///
/// The loop is generated in memory (no bundle file): 1s of 16-bit mono PCM with
/// ±1 LSB dither (~-90 dBFS, inaudible). Not pure digital zeros, in case iOS
/// treats an all-zero stream as "not really playing".
///
/// Reliability: restarts automatically after interruptions (calls, Siri,
/// navigation prompts), route changes (CarPlay / Bluetooth connect/disconnect)
/// and media-services resets. `ensurePlaying()` is also called as a watchdog.
/// Diagnostics: `statusReport()` logs session category/options/route and
/// whether the player is really advancing.
@MainActor
final class KeepAliveAudio {
    var onLog: (String) -> Void = { _ in }

    private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var sessionActivated = false
    private var observers: [NSObjectProtocol] = []
    private var lastReportedTime: TimeInterval = -1

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            var reasonText = ""
            if #available(iOS 17.0, *),
               let r = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt {
                reasonText = " reason=\(r)"
            }
            Task { @MainActor in self?.handleInterruption(type, shouldResume: shouldResume, detail: reasonText) }
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
                self.sessionActivated = false
                if self.isActive { self.activateAndPlay(reason: "media reset") }
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            Task { @MainActor in self?.onLog("Audio: silence-secondary-audio hint type=\(raw ?? 99)") }
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
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            sessionActivated = false
        } catch {
            onLog("Audio: setActive(false) failed: \(error.localizedDescription)")
        }
        onLog("Audio: keep-alive stopped")
    }

    /// Watchdog: restart if something silently stopped the player.
    func ensurePlaying() {
        guard isActive else { return }
        if player?.isPlaying != true {
            onLog("Audio: watchdog found player NOT playing")
            activateAndPlay(reason: "watchdog")
        }
    }

    /// One-line diagnostic of the session + player.
    func statusReport() -> String {
        let s = AVAudioSession.sharedInstance()
        var opts: [String] = []
        if s.categoryOptions.contains(.mixWithOthers) { opts.append("mix") }
        if s.categoryOptions.contains(.duckOthers) { opts.append("duck") }
        if s.categoryOptions.contains(.interruptSpokenAudioAndMixWithOthers) { opts.append("interruptSpoken") }
        let outs = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let t = player?.currentTime ?? -1
        let advancing = lastReportedTime >= 0 ? (t != lastReportedTime ? "yes" : "NO") : "?"
        lastReportedTime = t
        let cat = s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let mode = s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        return "cat=\(cat) mode=\(mode) opts=[\(opts.joined(separator: ","))] active=\(sessionActivated) "
            + "player=\(player == nil ? "nil" : (player!.isPlaying ? "playing" : "STOPPED")) "
            + "t=\(String(format: "%.2f", t)) advancing=\(advancing) vol=\(player?.volume ?? -1) "
            + "otherAudio=\(s.isOtherAudioPlaying) route=\(outs)"
    }

    // MARK: - Private

    private func activateAndPlay(reason: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            onLog("Audio: setCategory FAILED (\(reason)): \(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
            sessionActivated = true
        } catch {
            sessionActivated = false
            onLog("Audio: setActive(true) FAILED (\(reason)): \(error.localizedDescription)")
            scheduleRetry()
            return
        }
        if player == nil {
            let data = Self.ditheredSilenceWAV()
            do {
                let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                p.numberOfLoops = -1
                p.volume = 1
                let prepared = p.prepareToPlay()
                player = p
                onLog("Audio: player created (\(data.count) bytes, dur=\(String(format: "%.2f", p.duration))s, "
                      + "fmt=\(p.format.sampleRate)Hz/\(p.format.channelCount)ch, prepared=\(prepared))")
            } catch {
                onLog("Audio: AVAudioPlayer init FAILED: \(error.localizedDescription)")
                scheduleRetry()
                return
            }
        }
        if player?.isPlaying != true {
            let ok = player?.play() ?? false
            if !ok {
                onLog("Audio: play() returned FALSE (\(reason))")
                scheduleRetry()
                return
            }
        }
        onLog("Audio: keep-alive OK (\(reason)) — \(statusReport())")
        // Verify a moment later that playback is really advancing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.isActive else { return }
            self.onLog("Audio: check after 1.5s — \(self.statusReport())")
        }
    }

    private func scheduleRetry() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isActive, self.player?.isPlaying != true else { return }
            self.activateAndPlay(reason: "retry")
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool, detail: String) {
        switch type {
        case .began:
            onLog("Audio: interruption BEGAN\(detail)")
        case .ended:
            onLog("Audio: interruption ENDED shouldResume=\(shouldResume)\(detail)")
            // Restart whether or not .shouldResume is set: we're silent and mixable.
            if isActive {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, self.isActive else { return }
                    self.activateAndPlay(reason: "after interruption")
                }
            }
        default:
            onLog("Audio: unknown interruption\(detail)")
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
        case .wakeFromSleep: name = "wake from sleep"
        case .noSuitableRouteForCategory: name = "no suitable route"
        default: name = "other"
        }
        onLog("Audio: route change (\(name)) -> \(outputs)")
        // Category changes are often caused by our own setCategory: don't loop.
        guard reason != .categoryChange else { return }
        if isActive { activateAndPlay(reason: "route change") }
    }

    /// 1 second of 16-bit mono PCM, ±1 LSB random dither (~-90 dBFS).
    private static func ditheredSilenceWAV(seconds: Double = 1, sampleRate: Int = 22050) -> Data {
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
        d.reserveCapacity(44 + dataSize)
        for _ in 0..<samples {
            withUnsafeBytes(of: Int16.random(in: -1...1).littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
