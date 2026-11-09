import SwiftUI

/// One lyric line with its own text direction.
///
/// RTL rule: the line gets its own `layoutDirection` and is aligned to
/// `.leading` (frame + multiline alignment). Inside a right-to-left environment
/// `.leading` resolves to the RIGHT edge, inside left-to-right to the LEFT edge.
/// Do NOT combine `.rightToLeft` with `.trailing`: that flips back to the left.
/// This also stays correct when the device language itself is Hebrew.
struct LyricLineText: View {
    let text: String
    let isRTL: Bool
    var font: Font
    var color: Color
    var lineLimit: Int = 1
    var minimumScaleFactor: CGFloat = 1
    var shadow: Color = .clear

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor)
            .multilineTextAlignment(.leading)
            .shadow(color: shadow, radius: 2, x: 0, y: 1)
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }
}

/// A line "slot" whose content slides up when the line changes.
///
/// The identity is `lineID + text`, so a new line is a new view: the old one
/// is pushed out at the top and the new one comes in from the bottom. Each
/// slot is clipped, so the stack rolls like a ticker instead of overlapping.
/// Heartbeat updates with identical content keep the identity -> no animation.
struct LyricSlot: View {
    let key: String
    let line: LyricLineText

    var body: some View {
        ZStack {
            line
                .id(key)
                .transition(.push(from: .bottom))
        }
        .padding(.vertical, 2) // room for the text shadow inside the clip
        .clipped()
    }
}

/// Apple-Music-style stack: previous (dimmed, small), current (large, bold),
/// next (dimmed, small). Used on the lock screen and as the in-app card.
struct LyricsStackView: View {
    let state: LyricsActivityAttributes.ContentState
    let theme: LyricsTheme
    var showsTrackInfo: Bool = true

    var body: some View {
        VStack(spacing: 6) {
            LyricSlot(key: "p\(state.lineID - 1)|\(state.previousLine)", line:
                LyricLineText(text: state.previousLine, isRTL: state.isRTLPrevious,
                              font: .system(size: 15, weight: .medium, design: .rounded),
                              color: theme.tertiaryText))
            LyricSlot(key: "c\(state.lineID)|\(state.currentLine)", line:
                LyricLineText(text: state.currentLine, isRTL: state.isRTLCurrent,
                              font: .system(size: 24, weight: .bold, design: .rounded),
                              color: theme.primaryText,
                              lineLimit: 2, minimumScaleFactor: 0.8,
                              shadow: theme.textShadow))
            LyricSlot(key: "n\(state.lineID + 1)|\(state.nextLine)", line:
                LyricLineText(text: state.nextLine, isRTL: state.isRTLNext,
                              font: .system(size: 15, weight: .medium, design: .rounded),
                              color: theme.secondaryText))
            if showsTrackInfo && !state.trackTitle.isEmpty {
                let info = state.artist.isEmpty ? state.trackTitle : "\(state.trackTitle) · \(state.artist)"
                LyricLineText(text: info, isRTL: TextDirection.isRTL(info),
                              font: .system(size: 11, weight: .semibold, design: .rounded),
                              color: theme.tertiaryText)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// Compact layout for the `.small` activity family (CarPlay dashboard, watchOS).
/// Current line as big as possible, next line underneath. No previous line,
/// no track info: the card is small and must be readable at a glance while driving.
struct CarPlayLyricsView: View {
    let state: LyricsActivityAttributes.ContentState
    let theme: LyricsTheme

    var body: some View {
        VStack(spacing: 2) {
            LyricSlot(key: "c\(state.lineID)|\(state.currentLine)", line:
                LyricLineText(text: state.currentLine, isRTL: state.isRTLCurrent,
                              font: .system(size: 20, weight: .bold, design: .rounded),
                              color: theme.primaryText,
                              lineLimit: 2, minimumScaleFactor: 0.6,
                              shadow: theme.textShadow))
            LyricSlot(key: "n\(state.lineID + 1)|\(state.nextLine)", line:
                LyricLineText(text: state.nextLine, isRTL: state.isRTLNext,
                              font: .system(size: 13, weight: .semibold, design: .rounded),
                              color: theme.secondaryText,
                              minimumScaleFactor: 0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
