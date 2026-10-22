import SwiftUI

/// BigTable on Apple Watch: tonight's meal and its steps, cooking timers, the grocery list and
/// Tell the Pantry. Everything comes from BigTable on the iPhone (WatchStore).
@main
struct BigTableWatchApp: App {
    @State private var store = WatchStore.shared
    @State private var timer = CookTimer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(timer)
                .tint(WatchTheme.accent)
                .task { store.start() }
        }
    }
}

enum WatchTheme {
    /// BigTable's color (the iPhone app's `Brand.defaultAccent`).
    static let accent = Color(red: 0xD9 / 255, green: 0x47 / 255, blue: 0x2B / 255)
    /// The color behind each page: the app's color fading into black, like the iPhone's header.
    static var background: some ShapeStyle { accent.gradient }
}
