import ActivityKit
import Foundation

/// Owns the lyrics Live Activity.
///
/// Update policy (kept minimal to stay within iOS update budgets):
/// - Send only when the content really changed (line, message, colors).
/// - Coalesce: never more than one update per `minUpdateInterval` (1s); a change
///   arriving sooner is sent on the next tick after the window (latest state wins).
/// - Heartbeat (same content, new staleDate) only after 15s WITHOUT any update,
///   so it never adds traffic while lines are changing.
/// - Every update carries `staleDate = now + 30s` -> a dead app shows
///   "Paused — tap to resume" instead of a frozen line.
/// - Each sent update gets a sequence number (`updateSeq`, "#N" in the log).
/// - `startFresh` ends ALL existing activities first (8-hour limit / leftovers).
/// - Logs what iOS reports via `contentUpdates` and `activityStateUpdates`.
@MainActor
final class LiveActivityController {
    typealias State = LyricsActivityAttributes.ContentState

    static let staleAfter: TimeInterval = 30
    static let heartbeatInterval: TimeInterval = 15
    static let minUpdateInterval: TimeInterval = 1

    var onLog: (String) -> Void = { _ in }
    /// Called when the current activity ends/is dismissed without us asking.
    var onEndedExternally: (ActivityState) -> Void = { _ in }

    private var activity: Activity<LyricsActivityAttributes>?
    /// Last sent content WITHOUT the seq stamp (used for change detection).
    private var lastState: State?
    private var lastSent = Date.distantPast
    private var seq = 0
    private var stateTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?

    var hasActivity: Bool { activity != nil }

    /// End every existing lyrics activity, then request a new one.
    @discardableResult
    func startFresh(_ state: State) -> Bool {
        endAll()
        return request(state)
    }

    /// Reuse a still-visible activity (e.g. after the app was relaunched),
    /// otherwise request a new one.
    @discardableResult
    func attachOrStart(_ state: State) -> Bool {
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            push(state, force: true)
            return true
        }
        let existing = Activity<LyricsActivityAttributes>.activities
            .first { $0.activityState == .active || $0.activityState == .stale }
        if let existing {
            onLog("Live Activity: re-attached \(existing.id.prefix(6))")
            activity = existing
            observe(existing)
            push(state, force: true)
            return true
        }
        return request(state)
    }

    /// Sends the state if it changed (coalesced to 1/s) or as an idle heartbeat.
    func push(_ state: State, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        let changed = state != lastState
        let sinceLast = now.timeIntervalSince(lastSent)

        let kind: String
        if force {
            kind = "forced"
        } else if changed {
            // Coalesce: wait until 1s since the last update; the next tick sends
            // whatever the newest state is by then.
            guard sinceLast >= Self.minUpdateInterval else { return }
            kind = "change"
        } else if sinceLast >= Self.heartbeatInterval {
            kind = "heartbeat"
        } else {
            return
        }

        lastState = state
        lastSent = now
        seq += 1
        let stamped = stamp(state)
        let content = ActivityContent(state: stamped, staleDate: now.addingTimeInterval(Self.staleAfter))
        let started = Date()
        Task { [weak self] in
            await activity.update(content)
            // update() doesn't throw; report how long it took and the activity state after.
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let line = stamped.currentLine.prefix(24)
            self?.onLog("LA send #\(stamped.updateSeq) [\(kind)] line \(stamped.lineID) \"\(line)\" -> \(activity.activityState) (\(ms)ms, app=\(LyricsSessionModel.appStateName()))")
        }
    }

    /// End the current activity, optionally showing a final message for a while.
    func end(final state: State? = nil, dismissAfter: TimeInterval = 0) {
        cancelObservers()
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let content = state.map { ActivityContent(state: stamp($0), staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = dismissAfter > 0
            ? .after(Date().addingTimeInterval(dismissAfter)) : .immediate
        Task { await activity.end(content, dismissalPolicy: policy) }
        onLog("Live Activity: ended")
    }

    func endAll() {
        cancelObservers()
        activity = nil
        lastState = nil
        let all = Activity<LyricsActivityAttributes>.activities
        for a in all {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        if !all.isEmpty { onLog("Live Activity: ended \(all.count) old activit\(all.count == 1 ? "y" : "ies")") }
    }

    static func authorizationReport() -> String {
        let info = ActivityAuthorizationInfo()
        return "areActivitiesEnabled=\(info.areActivitiesEnabled) frequentPushesEnabled=\(info.frequentPushesEnabled)"
    }

    // MARK: - Private

    private func stamp(_ state: State) -> State {
        var s = state
        s.updateSeq = seq
        return s
    }

    private func request(_ state: State) -> Bool {
        onLog("Live Activity auth: \(Self.authorizationReport())")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            onLog("Live Activity: disabled in Settings")
            return false
        }
        do {
            let now = Date()
            seq += 1
            let a = try Activity.request(
                attributes: LyricsActivityAttributes(),
                content: ActivityContent(state: stamp(state),
                                         staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = a
            lastState = state
            lastSent = now
            observe(a)
            onLog("Live Activity: started \(a.id.prefix(6)) #\(seq)")
            return true
        } catch {
            onLog("Live Activity: request failed: \(error.localizedDescription)")
            return false
        }
    }

    private func cancelObservers() {
        stateTask?.cancel()
        contentTask?.cancel()
        stateTask = nil
        contentTask = nil
    }

    private func observe(_ a: Activity<LyricsActivityAttributes>) {
        cancelObservers()
        let id = a.id

        stateTask = Task { [weak self] in
            for await state in a.activityStateUpdates {
                guard let self, !Task.isCancelled, self.activity?.id == id else { return }
                self.onLog("iOS activityState -> \(state)")
                if state == .ended || state == .dismissed {
                    self.activity = nil
                    self.lastState = nil
                    self.onLog("Live Activity: \(state) by system/user")
                    self.onEndedExternally(state)
                    return
                }
            }
        }

        contentTask = Task { [weak self] in
            for await content in a.contentUpdates {
                guard let self, !Task.isCancelled, self.activity?.id == id else { return }
                let stale = content.staleDate.map { Int($0.timeIntervalSinceNow) } ?? -1
                self.onLog("iOS contentUpdate #\(content.state.updateSeq) line \(content.state.lineID) staleIn=\(stale)s state=\(a.activityState)")
            }
        }
    }
}
