import ActivityKit
import Foundation

/// Owns the lyrics Live Activity.
///
/// - Every update carries `staleDate = now + 30s`; `push` also sends a heartbeat
///   at least every 15s, so a healthy session never looks stale, and a dead app
///   shows "Paused — tap to resume" instead of a frozen line.
/// - `startFresh` ends ALL existing activities first (8-hour limit / leftovers).
/// - Observes `activityStateUpdates` and reports when the system or the user
///   ends the activity while we still think it is running.
@MainActor
final class LiveActivityController {
    typealias State = LyricsActivityAttributes.ContentState

    static let staleAfter: TimeInterval = 30
    static let heartbeatInterval: TimeInterval = 15

    var onLog: (String) -> Void = { _ in }
    /// Called when the current activity ends/is dismissed without us asking.
    var onEndedExternally: (ActivityState) -> Void = { _ in }

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    private var lastSent = Date.distantPast
    private var observeTask: Task<Void, Never>?

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

    /// Sends the state if it changed, or as a heartbeat (refreshes staleDate).
    func push(_ state: State, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        let changed = state != lastState
        guard force || changed || now.timeIntervalSince(lastSent) >= Self.heartbeatInterval else { return }
        lastState = state
        lastSent = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    /// End the current activity, optionally showing a final message for a while.
    func end(final state: State? = nil, dismissAfter: TimeInterval = 0) {
        observeTask?.cancel()
        observeTask = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = dismissAfter > 0
            ? .after(Date().addingTimeInterval(dismissAfter)) : .immediate
        Task { await activity.end(content, dismissalPolicy: policy) }
        onLog("Live Activity: ended")
    }

    func endAll() {
        observeTask?.cancel()
        observeTask = nil
        activity = nil
        lastState = nil
        let all = Activity<LyricsActivityAttributes>.activities
        for a in all {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        if !all.isEmpty { onLog("Live Activity: ended \(all.count) old activit\(all.count == 1 ? "y" : "ies")") }
    }

    // MARK: - Private

    private func request(_ state: State) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            onLog("Live Activity: disabled in Settings")
            return false
        }
        do {
            let now = Date()
            let a = try Activity.request(
                attributes: LyricsActivityAttributes(),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = a
            lastState = state
            lastSent = now
            observe(a)
            onLog("Live Activity: started \(a.id.prefix(6))")
            return true
        } catch {
            onLog("Live Activity: request failed: \(error.localizedDescription)")
            return false
        }
    }

    private func observe(_ a: Activity<LyricsActivityAttributes>) {
        observeTask?.cancel()
        let id = a.id
        observeTask = Task { [weak self] in
            for await state in a.activityStateUpdates {
                guard let self, !Task.isCancelled, self.activity?.id == id else { return }
                if state == .ended || state == .dismissed {
                    self.activity = nil
                    self.lastState = nil
                    self.onLog("Live Activity: \(state) by system/user")
                    self.onEndedExternally(state)
                    return
                }
            }
        }
    }
}
