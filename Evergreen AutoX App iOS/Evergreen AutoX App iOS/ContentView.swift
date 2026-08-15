import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        RootView()
            .environment(model)
            .task { await model.start() }
    }
}

#Preview {
    ContentView()
}
