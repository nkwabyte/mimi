//
//  HistoryView.swift
//  Mimi
//

import SwiftUI

struct HistoryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("History stays in Terminal", systemImage: "clock")
        } description: {
            Text("Quarantine runs can be listed, restored, and purged with the mimi command. This app does not restore or purge yet: a restore still trusts the paths written in a run's manifest, and that has to be fixed before a button can move files back.")
        } actions: {
            VStack(alignment: .leading, spacing: 6) {
                Text("mimi history").font(.body.monospaced())
                Text("mimi restore <run-id>").font(.body.monospaced())
                Text("mimi purge <run-id>").font(.body.monospaced())
            }
            .textSelection(.enabled)
        }
        .navigationTitle("History")
    }
}
