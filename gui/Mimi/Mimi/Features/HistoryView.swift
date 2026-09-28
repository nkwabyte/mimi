//
//  HistoryView.swift
//  Mimi
//

import AppKit
import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @State private var filter: HistoryFilter = .all
    @State private var confirmDelete = false
    @State private var confirmClearAll = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            if let notice = store.notice {
                NoticeBanner(text: notice)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !store.selection.isEmpty {
                selectionBar
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload history from the engine")
                .disabled(store.state == .loading || store.isWorking)
            }
        }
        .task { if store.state == .idle { await store.load() } }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteButtonTitle, role: .destructive) {
                Task { await store.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog("Clear all history and logs?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear History and Logs", role: .destructive) {
                Task { await store.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every activity record and every log file mimi saved is deleted. Restorable quarantine runs are kept; purge them separately.")
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.title2.bold())
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(!hasClearable || store.isWorking)
                .help("Delete every history record and log file")
            }
            Picker("Show", selection: $filter) {
                ForEach(HistoryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Show")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var summary: String {
        let activity = store.items(in: .activity).count
        let runs = store.items(in: .quarantine).count
        let logs = store.items(in: .logs).count
        return "\(activity) record\(activity == 1 ? "" : "s") · \(runs) restorable run\(runs == 1 ? "" : "s") · \(logs) log file\(logs == 1 ? "" : "s")"
    }

    private var hasClearable: Bool {
        !store.items(in: .activity).isEmpty || !store.items(in: .logs).isEmpty
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading where store.items.isEmpty:
            ProgressView("Loading history…")
        case .failed(let message) where store.items.isEmpty:
            ContentUnavailableView {
                Label("History could not be loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await store.load() } }
            }
        default:
            if visibleSections.allSatisfy({ store.items(in: $0).isEmpty }) {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Cleans, uninstalls, restores, and their log files appear here after they run.")
                )
            } else {
                list
            }
        }
    }

    private var visibleSections: [HistorySection] {
        filter.sections
    }

    private var list: some View {
        @Bindable var store = store
        return List(selection: $store.selection) {
            ForEach(visibleSections) { section in
                let rows = store.items(in: section)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { item in
                            HistoryRow(
                                item: item,
                                isSelected: store.selection.contains(item.id),
                                toggle: { toggle(item) }
                            )
                            .tag(item.id)
                            .contextMenu { rowMenu(for: item) }
                        }
                    } header: {
                        SectionHeader(section: section, rows: rows, selection: $store.selection)
                    }
                }
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 60)
        .disabled(store.isWorking)
    }

    @ViewBuilder
    private func rowMenu(for item: HistoryItem) -> some View {
        if item.section == .logs {
            Button("Show in Finder") { reveal(logNamed: item.engineKey) }
            Button("Open Log") { open(logNamed: item.engineKey) }
            Divider()
        }
        Button(store.selection.contains(item.id) ? "Deselect" : "Select") { toggle(item) }
        Button(item.section == .quarantine ? "Purge…" : "Delete…", role: .destructive) {
            store.selection = [item.id]
            confirmDelete = true
        }
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(store.selection.count) selected")
                .font(.callout.weight(.medium))
            Button("Deselect All") { store.selection.removeAll() }
                .buttonStyle(.link)
            Spacer()
            if store.isWorking {
                ProgressView().controlSize(.small)
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label(deleteButtonTitle, systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(store.isWorking)
            .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectedCounts: (records: Int, runs: Int, logs: Int, runBytes: Int64) {
        let chosen = store.selectedItems
        let runs = chosen.filter { $0.section == .quarantine }
        return (
            chosen.filter { $0.section == .activity }.count,
            runs.count,
            chosen.filter { $0.section == .logs }.count,
            runs.reduce(0) { $0 + ($1.bytes ?? 0) }
        )
    }

    private var deleteButtonTitle: String {
        selectedCounts.runs > 0 && selectedCounts.records + selectedCounts.logs == 0 ? "Purge Selected" : "Delete Selected"
    }

    private var deleteTitle: String {
        "Delete \(store.selection.count) selected item\(store.selection.count == 1 ? "" : "s")?"
    }

    private var deleteMessage: String {
        let counts = selectedCounts
        var lines: [String] = []
        if counts.records > 0 {
            lines.append("\(counts.records) history record\(counts.records == 1 ? "" : "s") will be removed.")
        }
        if counts.logs > 0 {
            lines.append("\(counts.logs) log file\(counts.logs == 1 ? "" : "s") will be deleted.")
        }
        if counts.runs > 0 {
            let size = ByteCountFormatter.string(fromByteCount: counts.runBytes, countStyle: .file)
            lines.append("\(counts.runs) quarantine run\(counts.runs == 1 ? "" : "s") will be purged, freeing \(size). Purged files cannot be restored.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func toggle(_ item: HistoryItem) {
        if store.selection.contains(item.id) {
            store.selection.remove(item.id)
        } else {
            store.selection.insert(item.id)
        }
    }

    private func logURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mimi", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func reveal(logNamed name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([logURL(name)])
    }

    private func open(logNamed name: String) {
        NSWorkspace.shared.open(logURL(name))
    }
}

// MARK: - Filter

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, activity, quarantine, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .activity: "Activity"
        case .quarantine: "Restorable"
        case .logs: "Logs"
        }
    }

    var sections: [HistorySection] {
        switch self {
        case .all: HistorySection.allCases
        case .activity: [.activity]
        case .quarantine: [.quarantine]
        case .logs: [.logs]
        }
    }
}

// MARK: - Rows

private struct SectionHeader: View {
    let section: HistorySection
    let rows: [HistoryItem]
    @Binding var selection: Set<HistoryItem.ID>

    private var allSelected: Bool {
        rows.allSatisfy { selection.contains($0.id) }
    }

    var body: some View {
        HStack {
            Text(section.title)
                .font(.headline)
            Text("\(rows.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            Button(allSelected ? "Deselect All" : "Select All") {
                let ids = Set(rows.map(\.id))
                if allSelected {
                    selection.subtract(ids)
                } else {
                    selection.formUnion(ids)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect" : "Select")

            IconTile(kind: item.kind)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let status = item.status {
                        StatusBadge(status: status)
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                if let bytes = item.bytes, bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.callout.weight(.medium).monospacedDigit())
                }
                if let date = item.date {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        var parts = [item.kind.label, item.title]
        if let status = item.status { parts.append(status) }
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        return parts.joined(separator: ", ")
    }
}

/// A rounded, tinted square holding the row's symbol.
struct IconTile: View {
    let kind: HistoryKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch kind {
        case .clean: .teal
        case .apply: .blue
        case .restore: .green
        case .purge: .red
        case .expire: .gray
        case .uninstall: .pink
        case .caskUninstall: .orange
        case .vendorUninstaller: .brown
        case .systemRequest: .indigo
        case .quarantineRun: .purple
        case .log: .secondary
        case .orphanReview: .mint
        case .other: .secondary
        }
    }
}

private struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch status {
        case "ok", "written": .green
        case "partial": .orange
        case "failed", "refused": .red
        case "cancelled", "interrupted": .secondary
        default: .secondary
        }
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview("History") {
    HistoryView()
        .environment(HistoryStore(engine: MockEngineClient()))
        .frame(width: 820, height: 620)
}
