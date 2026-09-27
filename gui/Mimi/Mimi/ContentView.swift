//
//  ContentView.swift
//  Mimi
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem = .cleaner

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            switch selection {
            case .cleaner:
                CleanerView()
            case .overview:
                DashboardView()
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

#Preview("Scan results") {
    PreviewShell()
}

private struct PreviewShell: View {
    @State private var model = AppModel(engine: MockEngineClient())

    var body: some View {
        ContentView()
            .environment(model)
            .task { model.scan() }
    }
}
