import SwiftUI

@main
struct TrinetraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(model.menuBarIcon)
                .accessibilityLabel(model.headline)
        }
        .menuBarExtraStyle(.window)
    }
}
