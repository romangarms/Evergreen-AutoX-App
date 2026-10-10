//
//  Evergreen_AutoX_App_iOSApp.swift
//  Evergreen AutoX App iOS
//
//  Created by Roman Garms on 8/13/26.
//

import SwiftUI

@main
struct Evergreen_AutoX_App_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
