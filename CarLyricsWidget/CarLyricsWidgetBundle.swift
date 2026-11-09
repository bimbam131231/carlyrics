import SwiftUI
import WidgetKit

@main
struct CarLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 18.0, *) {
            LyricsLiveActivityWithSmall()
        } else {
            LyricsLiveActivity()
        }
    }
}
