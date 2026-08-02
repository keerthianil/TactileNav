//
//  TactileNavApp.swift
//  TactileNav
//
//  Created by Vatsalya's Mac on 5/18/26.
//

import SwiftUI

/// Portrait only.
///
/// Every size on the map is a physical millimetre measurement, and the viewport is centred on
/// a fixed point. Rotating mid-exploration moves the whole map out from under the finger,
/// which for someone navigating by touch means losing their place with no way to recover it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
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
