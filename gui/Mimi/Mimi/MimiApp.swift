//
//  MimiApp.swift
//  Mimi
//
//  Created by Musah Ibrahim Ali on 9/27/26.
//

import SwiftUI

@main
struct MimiApp: App {
    @State private var model: AppModel
    @State private var history: HistoryStore

    init() {
        let engine = ProcessEngineClient()
        _model = State(initialValue: AppModel(engine: engine))
        _history = State(initialValue: HistoryStore(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(history)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {} // no duplicate document windows
        }
    }
}
