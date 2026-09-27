//
//  SettingsView.swift
//  Mimi
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("This app") {
                LabeledContent("Engine") {
                    Text(model.engineLocation)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Text("Profiles in the Cleaner only choose what a scan reports. They are not saved, and this app does not write ~/.config/mimi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Not in this app") {
                Text("Whitelist, risky confirmation, and --force-risky stay on the command line. Saving them here could authorize a later run the person did not mean to authorize.")
                Text("System-scope uninstall is not shown. The root helper can still be pointed at a copy of itself that the user can edit.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
