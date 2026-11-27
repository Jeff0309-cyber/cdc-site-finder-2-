import GoogleMaps
import SwiftUI

@main
struct SiteFinderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: SiteModel

    init() {
        #if DEBUG
        DemoLaunch.prepare()
        #endif
        _model = State(initialValue: SiteModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(Theme.brown)
                #if DEBUG
                .task { DemoLaunch.apply(to: model) }
                #endif
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let key = GoogleMapsConfig.apiKey {
            GMSServices.provideAPIKey(key)
        }
        return true
    }
}
