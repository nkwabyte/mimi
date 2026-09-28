//
//  DashboardView.swift
//  Mimi
//

import Foundation
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem
    @State private var launchError: String?

    /// Cards stay between 260 and 420 points wide; a wider window gets more
    /// columns instead of wider cards.
    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16, alignment: .top)]

    /// Past this width the content stops growing and is centered, so a
    /// full-screen window does not leave everything against the left edge.
    private let maxContentWidth: CGFloat = 1_600

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overview")
                        .font(.largeTitle.bold())
                    engineLine
                }

                LastScanCard(model: model) {
                    selection = .cleaner
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Everything mimi can do")
                        .font(.title3.bold())
                    Text("Scanning and history work in this window. The rest opens in Terminal, where mimi asks you to confirm anything it deletes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(Feature.all) { feature in
                            FeatureCard(feature: feature) { perform(feature) }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            // The scrolled content spans the whole window, so the scroll bar
            // sits at the window's edge and the column is centered in it.
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Overview")
        .alert("Could not open Terminal", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchError ?? "")
        }
    }

    private var engineLine: some View {
        HStack(spacing: 6) {
            Image(systemName: model.engineExecutable == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(model.engineExecutable == nil ? Color.orange : Color.green)
            Text(model.engineVersion.isEmpty ? "Engine" : "Engine \(model.engineVersion)")
                .font(.callout.weight(.medium))
            Text(model.engineLocation)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func perform(_ feature: Feature) {
        switch feature.action {
        case .scan:
            selection = .cleaner
            model.scan()
        case .open(let item):
            selection = item
        case .terminal:
            do {
                try TerminalLauncher.run(engine: model.engineExecutable, arguments: feature.arguments)
            } catch {
                launchError = error.localizedDescription
            }
        }
    }
}

// MARK: - Features

struct Feature: Identifiable {
    enum Action {
        case scan
        case open(SidebarItem)
        case terminal
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    /// The CLI arguments this card stands for (shown, copied, or run).
    let arguments: [String]
    let action: Action

    var buttonTitle: String {
        switch action {
        case .scan: "Scan Now"
        case .open: "Open"
        case .terminal: "Run in Terminal"
        }
    }

    static let all: [Feature] = [
        Feature(id: "scan", title: "Scan", detail: "See how much junk and developer cache can be freed. Scanning deletes nothing.",
                symbol: "sparkles", tint: .teal, arguments: ["scan"], action: .scan),
        Feature(id: "clean", title: "Clean", detail: "Remove junk for the selected profile, after you confirm what goes.",
                symbol: "trash", tint: .red, arguments: ["clean"], action: .terminal),
        Feature(id: "choose", title: "Choose Categories", detail: "Tick categories one by one in the interactive picker, then scan or clean them.",
                symbol: "checklist", tint: .blue, arguments: [], action: .terminal),
        Feature(id: "plan", title: "Plan and Apply", detail: "Write a reviewable plan first; applying it moves files to a restorable quarantine.",
                symbol: "list.bullet.clipboard", tint: .indigo, arguments: ["plan"], action: .terminal),
        Feature(id: "uninstall", title: "Uninstall Apps", detail: "Pick installed apps from a list and remove them with the files they leave behind.",
                symbol: "xmark.bin", tint: .pink, arguments: ["uninstall"], action: .terminal),
        Feature(id: "apps", title: "Installed Apps", detail: "List every installed app with where it came from: App Store, Homebrew, package, or download.",
                symbol: "square.grid.3x3", tint: .orange, arguments: ["apps"], action: .terminal),
        Feature(id: "leftovers", title: "Leftover Files", detail: "Find support files left behind by apps you already removed.",
                symbol: "questionmark.folder", tint: .mint, arguments: ["scan", "--only", "orphans", "--include-orphans"], action: .terminal),
        Feature(id: "report", title: "Disk Report", detail: "Where your space went: virtual machines, SDKs, model weights, node_modules, large files.",
                symbol: "chart.pie", tint: .purple, arguments: ["--report"], action: .terminal),
        Feature(id: "history", title: "History and Restore", detail: "What mimi did, the runs you can still restore, and the logs it kept. Clear them here.",
                symbol: "clock.arrow.circlepath", tint: .green, arguments: ["history"], action: .open(.history)),
        Feature(id: "whitelist", title: "Whitelist", detail: "Protect folders mimi must never touch, such as simulators or model caches.",
                symbol: "hand.raised", tint: .yellow, arguments: [], action: .terminal),
        Feature(id: "profiles", title: "Profiles", detail: "Safe, Developer, or Aggressive: choose how much a scan looks at.",
                symbol: "slider.horizontal.3", tint: .cyan, arguments: ["--profile", "list"], action: .open(.cleaner)),
    ]
}

private struct FeatureCard: View {
    let feature: Feature
    let run: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(feature.tint)
                    .frame(width: 42, height: 42)
                    .background(feature.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer()
                if case .terminal = feature.action {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Runs in Terminal")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(TerminalLauncher.displayCommand(feature.arguments))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .textSelection(.enabled)

            HStack {
                Button(feature.buttonTitle, action: run)
                    .buttonStyle(.borderedProminent)
                    .tint(feature.tint)
                Spacer()
                Button {
                    TerminalLauncher.copy(feature.arguments)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help("Copy the command")
                .accessibilityLabel("Copy command")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? feature.tint.opacity(0.5) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.10 : 0.04), radius: hovering ? 10 : 4, y: 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(feature.title)
    }
}

private struct LastScanCard: View {
    let model: AppModel
    let openCleaner: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.title3.bold())
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
            Button("Open Cleaner", action: openCleaner)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private var found: String {
        ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)
    }

    private var headline: String {
        switch model.state {
        case .idle: "No scan yet"
        case .running: model.phase.isEmpty ? "Scanning…" : "Scanning \(model.phase)…"
        case .finished: "\(found) can be freed"
        case .failed: "The last scan failed"
        case .cancelled: "The last scan was cancelled"
        }
    }

    private var detail: String {
        switch model.state {
        case .idle:
            "Scan to see what the \(model.profile.title) profile would free. Nothing is deleted."
        case .running:
            "\(model.candidates.count) item\(model.candidates.count == 1 ? "" : "s") so far."
        case .finished:
            "\(model.candidates.count) item\(model.candidates.count == 1 ? "" : "s") found with the \(model.profile.title) profile. Nothing was deleted."
        case .failed(let message):
            message
        case .cancelled:
            "Nothing was deleted."
        }
    }

    private var symbol: String {
        switch model.state {
        case .idle: "sparkles"
        case .running: "hourglass"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private var tint: Color {
        switch model.state {
        case .failed: .orange
        case .cancelled: .secondary
        default: .teal
        }
    }
}

#Preview("Overview") {
    OverviewPreview()
}

private struct OverviewPreview: View {
    @State private var selection: SidebarItem = .overview
    @State private var model = AppModel(engine: MockEngineClient())

    var body: some View {
        DashboardView(selection: $selection)
            .environment(model)
            .frame(width: 980, height: 760)
    }
}
