import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

typealias LyricsState = LyricsActivityAttributes.ContentState

// MARK: - Animation notes (iOS limits for Live Activities)
//
// Live Activity views are rendered by the system from archived snapshots, not
// by a running SwiftUI app, so animation is restricted:
// - Only changes between two ContentState updates animate. There is no
//   continuous animation, no timers/TimelineView driving frames, no
//   `withAnimation` from our code (only `Text(timerInterval:)` /
//   `ProgressView(timerInterval:)` tick on their own).
// - What works: `.transition(...)` on views whose `.id()` changes (we use
//   `.push(from: .bottom)` per line slot -> lines slide up), and
//   `.contentTransition(...)` (`.opacity`, `.interpolate`, `.numericText`)
//   for in-place text changes.
// - The system picks the timing; custom springs/durations are ignored or
//   clamped (max ~2s). Animations may be skipped entirely when the device is
//   in Low Power Mode, on the Always-On display, or when updates arrive faster
//   than the system will animate them.
// - CarPlay / watchOS (`.small`) may show a reduced or no animation at all.
// So the real "Apple Music" spring scrolling only exists in the app
// (`ScrollingLyricsView`); the Live Activity gets the closest equivalent.

private let resumeURL = URL(string: "carlyrics://resume")

// MARK: - Diagnostics: update counter + minimal mode

/// Tiny "#N" in the corner: the sequence number of the update iOS rendered.
struct UpdateCounter: View {
    let seq: Int
    var body: some View {
        Text("#\(seq)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(5)
    }
}

/// Diagnostic layout (app toggle "Minimal Live Activity"): plain white text on
/// black. No gradient, shadow, custom fonts, transitions or animation — to test
/// whether rendering cost (extension memory/time limits) is why updates stop.
struct MinimalLyricsView: View {
    let state: LyricsState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isStale ? "Paused — tap to resume" : state.currentLine)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            if !isStale {
                Text(state.nextLine)
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .overlay(alignment: .topTrailing) { UpdateCounter(seq: state.updateSeq) }
        .background(Color.black)
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
        .transaction { t in
            t.animation = nil
            t.disablesAnimations = true
        }
    }
}

// MARK: - Stale ("Paused — tap to resume")

/// Shown whenever `context.isStale` (the app stopped sending heartbeats):
/// never show a frozen old lyric line.
struct StaleLyricsView: View {
    let state: LyricsState
    let compact: Bool

    var body: some View {
        let theme = LyricsTheme(state: state)
        VStack(spacing: compact ? 6 : 10) {
            Text("Paused — tap to resume")
                .font(.system(size: compact ? 15 : 20, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: theme.textShadow, radius: 2, x: 0, y: 1)
            Button(intent: ResumeLyricsIntent()) {
                Label("Resume", systemImage: "play.fill")
                    .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primaryText)
        }
        .padding(compact ? 10 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lock screen / banner (.medium)

struct LockScreenLyricsView: View {
    let state: LyricsState
    let isStale: Bool

    var body: some View {
        let theme = LyricsTheme(state: state)
        Group {
            if isStale {
                StaleLyricsView(state: state, compact: false)
            } else {
                LyricsStackView(state: state, theme: theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { UpdateCounter(seq: state.updateSeq) }
        .background(LyricsBackground(theme: theme))
        .activityBackgroundTint(theme.tint)
        .activitySystemActionForegroundColor(theme.primaryText)
    }
}

// MARK: - CarPlay dashboard / watchOS (.small)

struct SmallLyricsActivityView: View {
    let state: LyricsState
    let isStale: Bool

    var body: some View {
        let theme = LyricsTheme(state: state)
        Group {
            if isStale {
                StaleLyricsView(state: state, compact: true)
            } else {
                CarPlayLyricsView(state: state, theme: theme)
            }
        }
        .overlay(alignment: .topTrailing) { UpdateCounter(seq: state.updateSeq) }
        .background(LyricsBackground(theme: theme))
        .activityBackgroundTint(theme.tint)
        .activitySystemActionForegroundColor(theme.primaryText)
    }
}

@available(iOS 18.0, *)
struct FamilyAwareLyricsView: View {
    @Environment(\.activityFamily) private var family
    let state: LyricsState
    let isStale: Bool

    var body: some View {
        switch family {
        case .small:
            SmallLyricsActivityView(state: state, isStale: isStale)
        case .medium:
            LockScreenLyricsView(state: state, isStale: isStale)
        @unknown default:
            LockScreenLyricsView(state: state, isStale: isStale)
        }
    }
}

struct LyricsActivityContentView: View {
    let state: LyricsState
    let isStale: Bool

    var body: some View {
        Group {
            if state.minimal {
                MinimalLyricsView(state: state, isStale: isStale)
            } else if #available(iOS 18.0, *) {
                FamilyAwareLyricsView(state: state, isStale: isStale)
            } else {
                LockScreenLyricsView(state: state, isStale: isStale)
            }
        }
        .widgetURL(resumeURL)
    }
}

// MARK: - Dynamic Island (always on black)

enum LyricsDynamicIsland {
    static func make(_ state: LyricsState, isStale: Bool) -> DynamicIsland {
        if state.minimal { return makeMinimal(state, isStale: isStale) }
        let accent = LyricsTheme(state: state).accent.color
        return DynamicIsland {
            DynamicIslandExpandedRegion(.bottom) {
                if isStale {
                    HStack {
                        Text("Paused — tap to resume")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Button(intent: ResumeLyricsIntent()) {
                            Image(systemName: "play.fill")
                        }
                        .tint(accent)
                    }
                    .padding(.horizontal, 6)
                } else {
                    VStack(spacing: 2) {
                        LyricSlot(key: "c\(state.lineID)|\(state.currentLine)", line:
                            LyricLineText(text: state.currentLine, isRTL: state.isRTLCurrent,
                                          font: .system(size: 18, weight: .bold, design: .rounded),
                                          color: .white, lineLimit: 2, minimumScaleFactor: 0.8))
                        LyricSlot(key: "n\(state.lineID + 1)|\(state.nextLine)", line:
                            LyricLineText(text: state.nextLine, isRTL: state.isRTLNext,
                                          font: .system(size: 13, weight: .medium, design: .rounded),
                                          color: .white.opacity(0.55)))
                    }
                    .padding(.horizontal, 6)
                }
            }
        } compactLeading: {
            Image(systemName: isStale ? "pause.fill" : "music.note").foregroundStyle(accent)
        } compactTrailing: {
            Text(isStale ? "Paused" : state.currentLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: 90)
                .id("c\(state.lineID)|\(isStale)|\(state.currentLine)")
                .transition(.push(from: .bottom))
        } minimal: {
            Image(systemName: isStale ? "pause.fill" : "music.note").foregroundStyle(accent)
        }
        .keylineTint(accent)
        .widgetURL(resumeURL)
    }

    private static func makeMinimal(_ state: LyricsState, isStale: Bool) -> DynamicIsland {
        let current = isStale ? "Paused — tap to resume" : state.currentLine
        return DynamicIsland {
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current).font(.system(size: 17, weight: .bold)).lineLimit(2)
                    Text("#\(state.updateSeq)").font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } compactLeading: {
            Text("#\(state.updateSeq)").font(.system(size: 10, design: .monospaced))
        } compactTrailing: {
            Text(current).font(.system(size: 12)).lineLimit(1).frame(maxWidth: 90)
        } minimal: {
            Image(systemName: "music.note")
        }
        .widgetURL(resumeURL)
    }
}

// MARK: - Widget

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityContentView(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            LyricsDynamicIsland.make(context.state, isStale: context.isStale)
        }
        .smallFamilyIfAvailable()
    }
}

extension WidgetConfiguration {
    /// iOS 18+: adds the `.small` family used by CarPlay (iOS 26) and watchOS.
    /// Relies on SE-0360 (opaque result types with limited availability):
    /// keep this exact `if #available { return } return self` shape.
    func smallFamilyIfAvailable() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return self.supplementalActivityFamilies([.small])
        }
        return self
    }
}
