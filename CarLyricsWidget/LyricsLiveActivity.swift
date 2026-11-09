import ActivityKit
import SwiftUI
import WidgetKit

typealias LyricsState = LyricsActivityAttributes.ContentState

// MARK: - Lock screen / banner (.medium)

struct LockScreenLyricsView: View {
    let state: LyricsState

    var body: some View {
        let theme = LyricsTheme(state: state)
        LyricsStackView(state: state, theme: theme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LyricsBackground(theme: theme))
            .activityBackgroundTint(theme.tint)
            .activitySystemActionForegroundColor(theme.primaryText)
    }
}

// MARK: - CarPlay dashboard / watchOS (.small)

struct SmallLyricsActivityView: View {
    let state: LyricsState

    var body: some View {
        let theme = LyricsTheme(state: state)
        CarPlayLyricsView(state: state, theme: theme)
            .background(LyricsBackground(theme: theme))
            .activityBackgroundTint(theme.tint)
            .activitySystemActionForegroundColor(theme.primaryText)
    }
}

@available(iOS 18.0, *)
struct FamilyAwareLyricsView: View {
    @Environment(\.activityFamily) private var family
    let state: LyricsState

    var body: some View {
        switch family {
        case .small:
            SmallLyricsActivityView(state: state)
        case .medium:
            LockScreenLyricsView(state: state)
        @unknown default:
            LockScreenLyricsView(state: state)
        }
    }
}

struct LyricsActivityContentView: View {
    let state: LyricsState

    var body: some View {
        if #available(iOS 18.0, *) {
            FamilyAwareLyricsView(state: state)
        } else {
            LockScreenLyricsView(state: state)
        }
    }
}

// MARK: - Dynamic Island (always on black)

enum LyricsDynamicIsland {
    static func make(_ state: LyricsState) -> DynamicIsland {
        let accent = LyricsTheme(state: state).accent.color
        return DynamicIsland {
            DynamicIslandExpandedRegion(.bottom) {
                VStack(spacing: 4) {
                    LyricLineText(text: state.currentLine, isRTL: state.isRTLCurrent,
                                  font: .system(size: 18, weight: .bold, design: .rounded),
                                  color: .white, lineLimit: 2, minimumScaleFactor: 0.8)
                    LyricLineText(text: state.nextLine, isRTL: state.isRTLNext,
                                  font: .system(size: 13, weight: .medium, design: .rounded),
                                  color: .white.opacity(0.55))
                }
                .padding(.horizontal, 6)
            }
        } compactLeading: {
            Image(systemName: "music.note").foregroundStyle(accent)
        } compactTrailing: {
            Text(state.currentLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: 90)
        } minimal: {
            Image(systemName: "music.note").foregroundStyle(accent)
        }
        .keylineTint(accent)
    }
}

// MARK: - Widgets

/// iOS 17: lock screen + Dynamic Island only.
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityContentView(state: context.state)
        } dynamicIsland: { context in
            LyricsDynamicIsland.make(context.state)
        }
    }
}

/// iOS 18+: adds the `.small` family used by CarPlay (iOS 26) and watchOS.
@available(iOS 18.0, *)
struct LyricsLiveActivityWithSmall: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityContentView(state: context.state)
        } dynamicIsland: { context in
            LyricsDynamicIsland.make(context.state)
        }
        .supplementalActivityFamilies([.small])
    }
}
