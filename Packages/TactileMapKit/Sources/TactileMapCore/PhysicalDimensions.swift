import CoreGraphics
import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif
import MapKit
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

public struct PhysicalDimensions {
    public static let lineWidthMM: CGFloat = 4.0
    public static let circleRadiusMM: CGFloat = 4.0

    // Device PPI (Pixels Per Inch) database - UPDATED WITH ALL DEVICES
    private static let devicePPI: [String: CGFloat] = [
        // iPhone 16 series
        "iPhone 16 Pro Max": 460,
        "iPhone 16 Pro": 460,
        "iPhone 16 Plus": 460,
        "iPhone 16": 460,

        // iPhone 15 series
        "iPhone 15 Pro Max": 460,
        "iPhone 15 Pro": 460,
        "iPhone 15 Plus": 476,
        "iPhone 15": 476,

        // iPhone 14 series
        "iPhone 14 Pro Max": 460,
        "iPhone 14 Pro": 460,
        "iPhone 14 Plus": 458,
        "iPhone 14": 476,

        // iPhone 13 series
        "iPhone 13 Pro Max": 458,
        "iPhone 13 Pro": 460,
        "iPhone 13": 460,
        "iPhone 13 mini": 476,

        // iPhone 12 series
        "iPhone 12 Pro Max": 458,
        "iPhone 12 Pro": 460,
        "iPhone 12": 460,
        "iPhone 12 mini": 476,

        // iPhone 11 series
        "iPhone 11 Pro Max": 458,
        "iPhone 11 Pro": 458,
        "iPhone 11": 326,  // LCD display

        // iPhone SE
        "iPhone SE (3rd generation)": 326,
        "iPhone SE (2nd generation)": 326,

        // iPads
        "iPad Pro 12.9-inch (6th generation)": 264,
        "iPad Pro 12.9-inch (5th generation)": 264,
        "iPad Pro 11-inch (4th generation)": 264,
        "iPad Pro 11-inch (3rd generation)": 264,
        "iPad Air (5th generation)": 264,
        "iPad Air (4th generation)": 264,
        "iPad (10th generation)": 264,
        "iPad (9th generation)": 264,
        "iPad mini (6th generation)": 326,
    ]

    // Identifier to PPI mapping for more accurate detection
    private static let identifierPPI: [String: CGFloat] = [
        // iPhone 16 series
        "iPhone17,4": 460,  // iPhone 16 Pro Max
        "iPhone17,3": 460,  // iPhone 16 Pro
        "iPhone17,2": 460,  // iPhone 16 Plus
        "iPhone17,1": 460,  // iPhone 16

        // iPhone 15 series
        "iPhone16,2": 460,  // iPhone 15 Pro Max
        "iPhone16,1": 460,  // iPhone 15 Pro
        "iPhone15,5": 476,  // iPhone 15 Plus
        "iPhone15,4": 476,  // iPhone 15

        // iPhone 14 series
        "iPhone15,3": 460,  // iPhone 14 Pro Max
        "iPhone15,2": 460,  // iPhone 14 Pro
        "iPhone14,8": 458,  // iPhone 14 Plus
        "iPhone14,7": 476,  // iPhone 14

        // iPhone 13 series
        "iPhone14,5": 458,  // iPhone 13 Pro Max
        "iPhone14,3": 460,  // iPhone 13 Pro
        "iPhone14,2": 460,  // iPhone 13
        "iPhone14,4": 476,  // iPhone 13 mini

        // iPhone 12 series
        "iPhone13,4": 458,  // iPhone 12 Pro Max
        "iPhone13,3": 460,  // iPhone 12 Pro
        "iPhone13,2": 460,  // iPhone 12
        "iPhone13,1": 476,  // iPhone 12 mini

        // iPhone 11 series
        "iPhone12,5": 458,  // iPhone 11 Pro Max
        "iPhone12,3": 458,  // iPhone 11 Pro
        "iPhone12,1": 326,  // iPhone 11 (LCD)

        // iPhone SE
        "iPhone14,6": 326,  // SE 3rd gen
        "iPhone12,8": 326,  // SE 2nd gen
    ]

    // Convert mm to screen points for UI elements
    public static func mmToPoints(_ mm: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        #else
        let scale: CGFloat = 2.0
        #endif
        let ppi = getCurrentDevicePPI()

        // Convert mm to inches, then to pixels, then to points
        let inches = mm / 25.4
        let pixels = inches * ppi
        let points = pixels / scale

        #if DEBUG
        print("Converting \(mm)mm to \(points) points (PPI: \(ppi), scale: \(scale))")
        #endif

        return points
    }

    // Convert mm to geographic radius for MKCircle based on current map view
    public static func mmToGeographicRadius(_ mm: CGFloat, mapView: MKMapView) -> CLLocationDistance {
        let region = mapView.region
        let mapWidthInMeters = region.span.longitudeDelta * 111000 * cos(region.center.latitude * .pi / 180)
        let mapViewWidthInPoints = mapView.frame.width

        let metersPerPoint = mapWidthInMeters / Double(mapViewWidthInPoints)
        let targetPoints = mmToPoints(mm)
        let radiusInMeters = CLLocationDistance(targetPoints) * metersPerPoint

        #if DEBUG
        print(" Map conversion: \(mm)mm -> \(targetPoints)pts -> \(radiusInMeters)m")
        #endif

        return radiusInMeters
    }

    public static func mmToMapMetersSimple(_ mm: CGFloat, zoomLevel: Double = 17.0) -> CLLocationDistance {
        let pointsPerMeter = 3.33
        let targetSizeInPoints = mmToPoints(mm)
        return CLLocationDistance(targetSizeInPoints / pointsPerMeter)
    }

    public static func mmToLineWidth(_ mm: CGFloat) -> CGFloat {
        let points = mmToPoints(mm)
        return max(points, 1.0)
    }

    public static func tactileElementSize() -> CGFloat {
        return mmToPoints(4.0)
    }

    private static func getScreenSizeInches() -> (width: Double, height: Double) {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        #else
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
        let scale: CGFloat = 2.0
        #endif
        let ppi = getCurrentDevicePPI()

        let widthPixels = bounds.width * scale
        let heightPixels = bounds.height * scale

        let widthInches = Double(widthPixels) / Double(ppi)
        let heightInches = Double(heightPixels) / Double(ppi)

        return (widthInches, heightInches)
    }

    public static func getCurrentDevicePPI() -> CGFloat {
        // Get the raw identifier
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        print("Raw Identifier: \(identifier)")

        // Check if running in simulator
        if identifier == "arm64" || identifier == "x86_64" || identifier.contains("Simulator") {
            // Get the simulated device from environment
            if let simulatedDevice = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
                print("Simulated Device Identifier: \(simulatedDevice)")

                // Try to get PPI from identifier mapping
                if let ppi = identifierPPI[simulatedDevice] {
                    print("Found PPI for simulated \(simulatedDevice): \(ppi)")
                    return ppi
                }
            }

            // Fallback: Try to determine from screen size
            #if canImport(UIKit)
            let screenHeight = UIScreen.main.nativeBounds.height
            let screenWidth = UIScreen.main.nativeBounds.width
            print("Simulator Screen: \(screenWidth) x \(screenHeight)")

            // iPhone 16/15/14 Pro Max: 1290 x 2796
            if screenHeight == 2796 && screenWidth == 1290 {
                return 460
            }

            // iPhone 16/15/14 Pro: 1179 x 2556
            if screenHeight == 2556 && screenWidth == 1179 {
                return 460
            }

            // iPhone 16/15: 1179 x 2556
            if screenHeight == 2556 && screenWidth == 1179 {
                return 476
            }

            // iPhone 13 Pro Max: 1284 x 2778
            if screenHeight == 2778 && screenWidth == 1284 {
                return 458
            }

            // iPhone 13/12 Pro: 1170 x 2532
            if screenHeight == 2532 && screenWidth == 1170 {
                return 460
            }
            #endif

            // Default for modern iPhones in simulator
            return 460
        }

        // Physical device - try identifier mapping first
        if let ppi = identifierPPI[identifier] {
            print("Found PPI for \(identifier): \(ppi)")
            return ppi
        }

        // Then try model name
        let deviceModel = getDeviceModel()
        if let ppi = devicePPI[deviceModel] {
            print("Found PPI for model \(deviceModel): \(ppi)")
            return ppi
        }

        // Fallback based on device type
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad {
            print("Using default iPad PPI: 264")
            return 264.0
        } else {
            print("Using default iPhone PPI: 460")
            return 460.0
        }
        #else
        print("Using default iPhone PPI: 460")
        return 460.0
        #endif
    }

    public static func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        // Map identifier to marketing name
        let deviceMap: [String: String] = [
            "iPhone17,4": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16",

            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone15,4": "iPhone 15",

            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone14,7": "iPhone 14",

            "iPhone14,5": "iPhone 13 Pro Max",
            "iPhone14,3": "iPhone 13 Pro",
            "iPhone14,2": "iPhone 13",
            "iPhone14,4": "iPhone 13 mini",

            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,2": "iPhone 12",
            "iPhone13,1": "iPhone 12 mini",

            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,1": "iPhone 11",

            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone12,8": "iPhone SE (2nd generation)",

            "arm64": "Simulator",
            "x86_64": "Simulator",
        ]

        if let marketingName = deviceMap[identifier] {
            return marketingName
        }

        // Check for simulator
        if identifier == "arm64" || identifier == "x86_64" {
            if let simulatedDevice = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
               let deviceName = deviceMap[simulatedDevice] {
                return "\(deviceName) (Simulator)"
            }
            return "Simulator"
        }

        return identifier
    }
}

extension PhysicalDimensions {
    public static func isIPad() -> Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    public static func supportsHaptics() -> Bool {
        #if canImport(CoreHaptics)
        if #available(iOS 13.0, macOS 10.15, *) {
            return CHHapticEngine.capabilitiesForHardware().supportsHaptics
        }
        #endif
        return false
    }

    public static func accessibleHitTarget(for mm: CGFloat) -> CGFloat {
        let converted = mmToPoints(mm)
        return max(converted, 44.0)
    }
}
