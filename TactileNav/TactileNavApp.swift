//
//  TactileNavApp.swift
//  TactileNav
//
//  Created by Vatsalya's Mac on 5/18/26.
//

import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        RTMOrientationLock.mask
    }
}

@main
struct TactileNavApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
