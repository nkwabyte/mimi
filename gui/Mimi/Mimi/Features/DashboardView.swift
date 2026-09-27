//
//  DashboardView.swift
//  Mimi
//

import Foundation
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Overview")
                    .font(.title2.bold())

                LabeledContent("Engine") {
                    Text(model.engineLocation)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                if !model.engineVersion.isEmpty {
                    LabeledContent("Version", value: model.engineVersion)
                }
                if !model.capabilities.isEmpty {
                    LabeledContent("Capabilities", value: model.capabilities.joined(separator: ", "))
                }

                Divider()

                switch model.state {
                case .idle:
                    Text("No scan yet. A scan lists what the safe, developer, or aggressive profile would consider. It does not remove files.")
                        .foregroundStyle(.secondary)
                case .running:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.phase.isEmpty ? "Scanning…" : "Scanning \(model.phase)…")
                    }
                    summaryCounts
                case .finished(let summary):
                    LabeledContent("Result", value: summary.status)
                    LabeledContent("Exit code", value: String(summary.exitCode))
                    LabeledContent(
                        "Scanned",
                        value: ByteCountFormatter.string(fromByteCount: summary.scannedKb * 1_024, countStyle: .file)
                    )
                    summaryCounts
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.orange)
                    if !model.candidates.isEmpty { summaryCounts }
                case .cancelled:
                    Text("The last scan was cancelled. Nothing was deleted.")
                        .foregroundStyle(.secondary)
                    if !model.candidates.isEmpty { summaryCounts }
                }

                if !model.permissionNotices.isEmpty {
                    Divider()
                    Text("Permissions")
                        .font(.headline)
                    ForEach(model.permissionNotices, id: \.self) { notice in
                        Text(notice)
                            .font(.callout)
                    }
                }

                Text("Cleaning is not offered in this window. System-scope uninstall is not offered either. Both stay in Terminal until the engine fixes in the security plan are done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Overview")
    }

    private var summaryCounts: some View {
        LabeledContent("Candidates", value: "\(model.candidates.count)")
    }
}
