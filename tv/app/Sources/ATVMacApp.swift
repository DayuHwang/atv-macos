// SPDX-License-Identifier: GPL-2.0-or-later
// atv-macos: the tvOS app. Everything runs on its own from launch; the screen
// (if a TV happens to be attached) only mirrors what the VNC card shows.
import SwiftUI

@main
struct ATVMacApp: App {
    init() {
        Log.start()
        Log.line("app", "atv-macos \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") starting")
        StatusServer.shared.start()
        RFBServer.shared.start(width: 1920, height: 1080)
        Host.shared.start()
    }

    var body: some Scene {
        WindowGroup { StatusView() }
    }
}

struct StatusView: View {
    @State private var status = HostStatus()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("atv-macos").font(.system(size: 56, weight: .semibold))
            Text(ScreenSource.phaseTitle(status.phase)).font(.title2)
            Text(status.detail).foregroundStyle(.secondary)
            if let p = status.progress { ProgressView(value: p).frame(maxWidth: 900) }
            Spacer()
            if let a = status.addresses.first {
                Text("VNC \(a):\(RFBServer.port)   ·   status http://\(a):\(StatusServer.port)").foregroundStyle(.secondary)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(timer) { _ in status = Host.shared.status }
    }
}
