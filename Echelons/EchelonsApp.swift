import SwiftUI

@main
struct EchelonsApp: App {
    @State private var session = ActivitySessionController()

    var body: some Scene {
        WindowGroup {
            ActivityView()
                .environment(session)
        }
    }
}
