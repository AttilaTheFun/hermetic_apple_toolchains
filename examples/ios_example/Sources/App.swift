import SwiftUI

@main
struct IOSExampleApp: App {
    init() {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    private var sdkName: String {
        Bundle.main.infoDictionary?["DTSDKName"] as? String ?? "unknown"
    }

    private var ios27Available: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("hermetic_apple_toolchains")
                .font(.headline)
            Text("Built against \(sdkName)")
            Text("iOS 27 APIs available: \(ios27Available ? "yes" : "no")")
            Text("Runtime: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
        .padding()
    }
}
