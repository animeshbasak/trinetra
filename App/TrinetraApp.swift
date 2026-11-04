import SwiftUI

@main
struct TrinetraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, monitor: model.monitor)
        } label: {
            HStack(spacing: 4) {
                Image(model.menuBarIcon)
                if let text = model.readoutText {
                    Text(text).monospacedDigit()
                }
            }
            .accessibilityLabel(model.headline)
        }
        .menuBarExtraStyle(.window)
    }
}
