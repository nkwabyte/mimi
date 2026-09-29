//
//  ContentView.swift
//  Mimi
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .overview

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            switch selection {
            case .cleaner:
                CleanerView()
            case .overview:
                DashboardView(selection: $selection)
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

#Preview("Scan results") {
    PreviewShell()
}

private struct PreviewShell: View {
    @State private var model = AppModel(engine: MockEngineClient())
    @State private var history = HistoryStore(engine: MockEngineClient())
    @State private var license = LicenseStore(storage: MemoryLicenseStorage())

    var body: some View {
        ContentView()
            .environment(model)
            .environment(history)
            .environment(license)
            .task { model.scan() }
    }
}
