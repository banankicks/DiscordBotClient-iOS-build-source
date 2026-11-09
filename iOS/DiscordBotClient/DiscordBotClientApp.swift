import SwiftUI

@main
struct DiscordBotClientApp: App {
    @StateObject private var model = DiscordClientModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
