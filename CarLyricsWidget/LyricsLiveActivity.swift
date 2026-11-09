import ActivityKit
import SwiftUI
import WidgetKit

struct LyricLineText: View {
    let text: String
    let isRTL: Bool
    var font: Font = .title3.bold()
    var lineLimit: Int = 2

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(font)
            .lineLimit(lineLimit)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }
}

struct LockScreenLyricsView: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LyricLineText(text: state.currentLine, isRTL: state.isRTLCurrent)
                .foregroundStyle(.white)
            LyricLineText(text: state.nextLine, isRTL: state.isRTLNext,
                          font: .subheadline, lineLimit: 1)
                .foregroundStyle(.white.opacity(0.55))
            if !state.trackTitle.isEmpty {
                Text("\(state.trackTitle) · \(state.artist)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding()
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyricsView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        LyricLineText(text: context.state.currentLine,
                                      isRTL: context.state.isRTLCurrent)
                        LyricLineText(text: context.state.nextLine,
                                      isRTL: context.state.isRTLNext,
                                      font: .caption, lineLimit: 1)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}
