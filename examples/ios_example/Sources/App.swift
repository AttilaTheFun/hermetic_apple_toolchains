import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let sdkName = info["DTSDKName"] as? String ?? "unknown"
        let sdkBuild = info["DTSDKBuild"] as? String ?? "unknown"
        NSLog("[hermetic] built against SDK: %@ (build %@)", sdkName, sdkBuild)

        if #available(iOS 27.0, *) {
            NSLog("[hermetic] if #available(iOS 27.0): iOS 27 APIs are available at runtime")
        } else {
            NSLog("[hermetic] if #available(iOS 27.0): not available, running on an older runtime")
        }

        NSLog("[hermetic] runtime OS: %@", ProcessInfo.processInfo.operatingSystemVersionString)
        return true
    }
}
