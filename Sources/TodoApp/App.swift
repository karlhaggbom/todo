import SwiftUI
import Todo

@main
struct TodoApp: App {
    @StateObject private var store = TodoStore()
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Todo") {
            RootView()
                .environmentObject(store)
                .environmentObject(appModel)
        }
        .windowToolbarStyle(.unified)
    }
}