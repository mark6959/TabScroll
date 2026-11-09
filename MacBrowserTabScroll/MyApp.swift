import SwiftUI

@main struct TabScrollApp: App {
    @StateObject private var controller: TabSwitchingController

    init() {
        let controller = TabSwitchingController()
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        MenuBarExtra("TabScroll", systemImage: "arrow.left.arrow.right") {
            ContentView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
