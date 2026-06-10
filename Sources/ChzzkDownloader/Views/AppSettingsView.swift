import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            RecordingSettingsView()
                .tabItem { Label("녹화", systemImage: "record.circle") }

            ConnectionSettingsView()
                .tabItem { Label("연결", systemImage: "network") }

            CookieSettingsView()
                .tabItem { Label("쿠키·로그", systemImage: "key") }
        }
        .frame(width: 560, height: 520)
        .scenePadding()
    }
}
