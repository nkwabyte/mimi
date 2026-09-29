//
//  SettingsView.swift
//  Mimi
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseStore.self) private var license
    @AppStorage(AppModel.defaultProfileKey) private var defaultProfile = ScanProfile.safe.rawValue

    var body: some View {
        Form {
            Section {
                LicenseSection()
            } header: {
                SectionTitle("Licence", symbol: "checkmark.seal")
            }

            Section {
                Picker("Default scan profile", selection: $defaultProfile) {
                    ForEach(ScanProfile.allCases) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                }
                .onChange(of: defaultProfile) { _, value in
                    if let profile = ScanProfile(rawValue: value), !model.isRunning {
                        model.profile = profile
                    }
                }
                Text(ScanProfile(rawValue: defaultProfile)?.detail ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionTitle("General", symbol: "gearshape")
            }

            Section {
                LabeledContent("Location") {
                    Text(model.engineLocation)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if !model.engineVersion.isEmpty {
                    LabeledContent("Version", value: model.engineVersion)
                }
                HStack {
                    Button("Show in Finder") {
                        if let url = model.engineExecutable {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(model.engineExecutable == nil)
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.engineExecutable?.path ?? model.engineLocation, forType: .string)
                    }
                }
                Text("The app runs the same mimi engine as the command line. It never writes ~/.config/mimi, and it does not offer --force-risky or system-scope uninstall.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionTitle("Engine", symbol: "terminal")
            }

            Section {
                FolderRow(title: "History", path: "~/.config/mimi/history.jsonl", relative: ".config/mimi/history.jsonl")
                FolderRow(title: "Logs", path: "~/Library/Logs/mimi", relative: "Library/Logs/mimi")
                FolderRow(title: "Quarantine", path: "~/Library/Application Support/mimi/quarantine", relative: "Library/Application Support/mimi/quarantine")
                Text("Scans and cleaning stay on this Mac. Nothing is uploaded. A licence key is checked on this Mac without contacting a server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionTitle("Data and Privacy", symbol: "hand.raised")
            }

            Section {
                LabeledContent("Mimi", value: appVersion)
                LabeledContent("Command-line tool", value: "Free and open source (MIT)")
                if !LicenseConfig.supportEmail.isEmpty,
                   let mail = URL(string: "mailto:\(LicenseConfig.supportEmail)") {
                    Link("Contact Support", destination: mail)
                }
                if let repo = URL(string: "https://github.com/nkwabyte/mimi") {
                    Link("Source Code and Issues", destination: repo)
                }
            } header: {
                SectionTitle("About", symbol: "info.circle")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { license.refresh() }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: - Licence

private struct LicenseSection: View {
    @Environment(LicenseStore.self) private var license
    @State private var keyText = ""
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LicenseStatusCard(status: license.status)

            if license.status.isLicensed {
                licensedActions
            } else {
                keyEntry
                PlanPicker()
            }

            Text("The mimi command-line tool is free. A licence unlocks the Mac app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .confirmationDialog("Remove the licence from this Mac?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Licence", role: .destructive) { license.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can enter the same key again later. Your purchase is not affected.")
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Licence key")
                .font(.headline)
            TextField("MIMI1.…", text: $keyText, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Licence key")
            if let message = license.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if !license.canVerify {
                Label("This build has no licence public key yet, so keys cannot be checked. See docs/LICENSING_PLAN.md.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Paste") {
                    if let text = NSPasteboard.general.string(forType: .string) { keyText = text }
                }
                Spacer()
                Button("Activate") {
                    if license.activate(keyText) { keyText = "" }
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var licensedActions: some View {
        HStack {
            if let portal = LicenseConfig.url(LicenseConfig.customerPortalURL) {
                Link(destination: portal) {
                    Label(license.status.payload?.plan == .monthly ? "Manage Subscription" : "Account", systemImage: "person.crop.circle")
                }
            }
            Spacer()
            Button("Remove Licence…", role: .destructive) { confirmRemove = true }
        }
    }
}

private struct LicenseStatusCard: View {
    let status: LicenseStatus

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                ForEach(details, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status {
        case .unlicensed: "Not licensed"
        case .active(let p): "\(p.plan.title) licence active"
        case .grace: "Subscription renewal pending"
        case .expired: "Subscription expired"
        case .invalid: "Licence could not be verified"
        }
    }

    private var details: [String] {
        switch status {
        case .unlicensed:
            return ["Buy a licence below, or paste the key from your receipt email."]
        case .active(let p):
            var lines = ["Registered to \(p.email)"]
            if let expires = p.expires {
                lines.append("Renews by \(expires.formatted(date: .abbreviated, time: .omitted))")
            } else {
                lines.append("One-time purchase, no expiry")
            }
            lines.append("Up to \(p.seats) Mac\(p.seats == 1 ? "" : "s") · licence \(p.id)")
            return lines
        case .grace(let p, let until):
            return [
                "Registered to \(p.email)",
                "The subscription period ended. Mimi keeps working until \(until.formatted(date: .abbreviated, time: .omitted)) while it renews.",
            ]
        case .expired(let p):
            return [
                "Registered to \(p.email)",
                "Renew from your account page, then paste the new key.",
            ]
        case .invalid(let message):
            return [message, "Paste your key again, or remove it."]
        }
    }

    private var symbol: String {
        switch status {
        case .active: "checkmark.seal.fill"
        case .grace: "clock.badge.exclamationmark"
        case .expired, .invalid: "exclamationmark.triangle.fill"
        case .unlicensed: "key"
        }
    }

    private var tint: Color {
        switch status {
        case .active: .green
        case .grace: .orange
        case .expired, .invalid: .red
        case .unlicensed: .blue
        }
    }
}

private struct PlanPicker: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlanCard(
                title: "Lifetime",
                price: LicenseConfig.lifetimePrice,
                cadence: "one-time",
                detail: "Pay once. All 1.x updates included.",
                symbol: "infinity",
                url: LicenseConfig.url(LicenseConfig.lifetimeCheckoutURL),
                highlighted: true
            )
            PlanCard(
                title: "Monthly",
                price: LicenseConfig.monthlyPrice,
                cadence: "per month",
                detail: "Every update while subscribed. Cancel any time.",
                symbol: "calendar",
                url: LicenseConfig.url(LicenseConfig.monthlyCheckoutURL),
                highlighted: false
            )
        }
    }
}

private struct PlanCard: View {
    let title: String
    let price: String
    let cadence: String
    let detail: String
    let symbol: String
    let url: URL?
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(price)
                    .font(.title.bold())
                Text(cadence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let url {
                Link(destination: url) {
                    Text("Buy \(title)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Store opens soon")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlighted ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: highlighted ? 1.5 : 1)
        }
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let text: String
    let symbol: String

    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
    }
}

private struct FolderRow: View {
    let title: String
    let path: String
    /// Path under the home folder.
    let relative: String

    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    let target = url
                    if FileManager.default.fileExists(atPath: target.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([target])
                    } else {
                        NSWorkspace.shared.open(target.deletingLastPathComponent())
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }
}

#Preview("Settings") {
    SettingsPreview()
}

private struct SettingsPreview: View {
    @State private var model = AppModel(engine: MockEngineClient())
    @State private var license = LicenseStore(storage: MemoryLicenseStorage())

    var body: some View {
        SettingsView()
            .environment(model)
            .environment(license)
            .frame(width: 760, height: 900)
    }
}
