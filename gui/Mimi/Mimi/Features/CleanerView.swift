//
//  CleanerView.swift
//  Mimi
//

import AppKit
import Foundation
import SwiftUI

struct CleanerView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header(model)
            notices
            Divider()
            body(for: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .navigationTitle("Cleaner")
    }

    private func header(_ model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleaner")
                        .font(.title2.bold())
                    if !model.engineVersion.isEmpty {
                        Text("Engine \(model.engineVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        model.scan()
                    } label: {
                        Label("Scan Mac", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }

            Picker("Profile", selection: $model.profile) {
                ForEach(ScanProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            .accessibilityLabel("Scan profile")

            Text(model.profile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Filter paths", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter candidates")
        }
        .padding()
    }

    @ViewBuilder
    private var notices: some View {
        if !model.permissionNotices.isEmpty || !model.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.permissionNotices, id: \.self) { notice in
                    NoticeRow(symbol: "exclamationmark.triangle.fill", text: notice, tint: .orange)
                }
                ForEach(model.warnings, id: \.self) { warning in
                    NoticeRow(symbol: "info.circle.fill", text: warning, tint: .secondary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func body(for model: AppModel) -> some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                "Ready to scan",
                systemImage: "sparkles",
                description: Text("Scan lists junk and developer caches. It does not delete them.")
            )
        case .running where model.candidates.isEmpty:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(model.phase.isEmpty ? "Scanning…" : "Scanning \(model.phase)…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message) where model.candidates.isEmpty:
            ContentUnavailableView(
                "Scan failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .cancelled where model.candidates.isEmpty:
            ContentUnavailableView(
                "Scan cancelled",
                systemImage: "xmark.circle",
                description: Text("Nothing was deleted.")
            )
        case .running, .finished(_), .cancelled, .failed(_):
            VStack(spacing: 0) {
                if case .failed(let message) = model.state {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", text: message, tint: .orange)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                if case .cancelled = model.state {
                    NoticeRow(symbol: "xmark.circle", text: "Scan cancelled. Rows below were found before it stopped.", tint: .secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                CandidateList(candidates: filtered(model.candidates), scanning: model.isRunning)
            }
        }
    }

    private var footer: some View {
        Text("Scanning does not delete anything. Cleaning, quarantine, and restore stay in Terminal until they are safe to offer here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
    }

    private func filtered(_ candidates: [Candidate]) -> [Candidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            $0.path.localizedCaseInsensitiveContains(trimmed)
                || $0.category.localizedCaseInsensitiveContains(trimmed)
                || $0.risk.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

private struct NoticeRow: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CandidateList: View {
    let candidates: [Candidate]
    var scanning: Bool = false

    private var sections: [(category: String, items: [Candidate], bytes: Int64)] {
        let grouped = Dictionary(grouping: candidates, by: \.category)
        return grouped.map { category, items in
            (category, items, items.reduce(0) { $0 + $1.bytes })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        if candidates.isEmpty {
            ContentUnavailableView(
                scanning ? "Still looking" : "Nothing to show",
                systemImage: scanning ? "sparkles" : "line.3.horizontal.decrease.circle",
                description: Text(scanning ? "Matches will appear here as the engine reports them." : "No rows match this filter.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(candidates.count) item\(candidates.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if scanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Scan in progress")
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                        .font(.subheadline.bold().monospacedDigit())
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                List {
                    ForEach(sections, id: \.category) { section in
                        Section {
                            ForEach(section.items) { candidate in
                                CandidateRow(candidate: candidate)
                            }
                        } header: {
                            HStack {
                                Text(section.category)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: section.bytes, countStyle: .file))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct CandidateRow: View {
    let candidate: Candidate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.category)
                        .font(.headline)
                    Text(candidate.risk)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(riskColor)
                        .background(riskColor.opacity(0.15), in: Capsule())
                }
                Text(candidate.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file))
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.category), \(candidate.risk), \(candidate.path)")
        .accessibilityValue(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file))
        .accessibilityAction(named: "Copy Path") { copyPath() }
        .contextMenu {
            Button("Reveal in Finder") { reveal() }
                .disabled(!FileManager.default.fileExists(atPath: candidate.path))
            Button("Copy Path") { copyPath() }
        }
    }

    private var riskColor: Color {
        switch candidate.risk {
        case "safe": .green
        case "moderate": .yellow
        case "risky": .orange
        case "irreversible": .red
        default: .secondary
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate.path, forType: .string)
    }
}
