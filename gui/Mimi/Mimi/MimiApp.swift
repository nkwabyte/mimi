//
//  MimiApp.swift
//  Mimi
//
//  Created by Musah Ibrahim Ali on 9/27/26.
//

import SwiftUI

@main
struct MimiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {} // no duplicate document windows
        }
    }
}
