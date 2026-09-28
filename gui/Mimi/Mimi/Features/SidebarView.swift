//
//  SidebarView.swift
//  Mimi
//

import SwiftUI

enum SidebarItem: Hashable, CaseIterable {
    case overview
    case cleaner
    case history
    case settings

    var label: String {
        switch self {
        case .cleaner: "Cleaner"
        case .overview: "Overview"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .cleaner: "sparkles"
        case .overview: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .settings: "gear"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem

    var body: some View {
        List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
            Label(item.label, systemImage: item.icon)
        }
        .listStyle(.sidebar)
        .navigationTitle("Mimi")
    }
}
