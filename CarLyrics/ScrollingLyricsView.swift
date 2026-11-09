import SwiftUI

/// In-app Apple-Music-style lyrics: the whole lyric list scrolls up with a
/// spring; the current line grows and brightens, the others shrink and dim.
/// (The Live Activity can't do this — see the notes in LyricsLiveActivity.swift.)
struct ScrollingLyricsView: View {
    let lines: [LyricLine]
    let currentIndex: Int?
    let theme: LyricsTheme
    var height: CGFloat = 210

    private let spring = Animation.spring(response: 0.55, dampingFraction: 0.85)
    private let beforeFirstID = -1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    // Spacers so the first/last line can sit in the middle.
                    Color.clear.frame(height: height / 2).id(beforeFirstID)
                    ForEach(lines.indices, id: \.self) { i in
                        row(i).id(i)
                    }
                    Color.clear.frame(height: height / 2)
                }
                .padding(.horizontal, 22)
            }
            .scrollDisabled(true)
            .frame(height: height)
            .onAppear {
                proxy.scrollTo(currentIndex ?? beforeFirstID, anchor: .center)
            }
            .onChange(of: currentIndex) { _, newValue in
                withAnimation(spring) {
                    proxy.scrollTo(newValue ?? beforeFirstID, anchor: .center)
                }
            }
        }
        // Fixed LTR container so the per-line scale anchors are absolute
        // (each line still sets its own direction inside LyricLineText).
        .environment(\.layoutDirection, .leftToRight)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.22),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func row(_ i: Int) -> some View {
        let isCurrent = i == currentIndex
        let distance = abs(i - (currentIndex ?? -1))
        let text = lines[i].text.isEmpty ? "♪" : lines[i].text
        let rtl = TextDirection.isRTL(text)
        return LyricLineText(
            text: text, isRTL: rtl,
            font: .system(size: 25, weight: .bold, design: .rounded),
            color: theme.primaryText,
            lineLimit: 3,
            shadow: isCurrent ? theme.textShadow : .clear
        )
        .scaleEffect(isCurrent ? 1 : 0.68, anchor: UnitPoint(x: rtl ? 1 : 0, y: 0.5))
        .opacity(isCurrent ? 1 : (distance == 1 ? 0.45 : 0.22))
        .blur(radius: isCurrent ? 0 : 0.5)
        .animation(spring, value: isCurrent)
    }
}
