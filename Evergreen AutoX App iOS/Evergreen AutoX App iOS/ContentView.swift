import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        RootView()
            .environment(model)
            .task { await model.start() }
            .onChange(of: model.watchContext, initial: true) { _, context in
                WatchSync.shared.send(context)
            }
    }
}

#Preview {
    ContentView()
}
