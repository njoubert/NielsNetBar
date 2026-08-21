import Foundation
import CoreWLAN
import CoreLocation

/// What CoreWLAN knows about an associated Wi-Fi interface.
struct WiFiInfo {
    /// nil when not associated — or when Location access has not been granted: since
    /// macOS 14 the SSID/BSSID are hidden from apps without it.
    var ssid: String?
    var bssid: String?
    var rssi: Int          // dBm
    var noise: Int         // dBm
    var txRate: Double     // Mbps, the PHY rate negotiated with the access point
    var channel: Int?
    var band: String?      // "2.4 GHz" / "5 GHz" / "6 GHz"
    var width: String?     // "80 MHz"
    var phyMode: String?   // "802.11ax"
    var security: String?
    var powerOn: Bool

    static func read(bsdName: String) -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(withName: bsdName) else { return nil }
        let ch = i.wlanChannel()
        return WiFiInfo(
            ssid: i.ssid(),
            bssid: i.bssid(),
            rssi: i.rssiValue(),
            noise: i.noiseMeasurement(),
            txRate: i.transmitRate(),
            channel: ch.map { $0.channelNumber },
            band: ch.flatMap { bandName($0.channelBand) },
            width: ch.flatMap { widthName($0.channelWidth) },
            phyMode: phyName(i.activePHYMode()),
            security: securityName(i.security()),
            powerOn: i.powerOn())
    }

    /// Associated means the radio reports a channel and a non-zero rate; the SSID alone
    /// cannot tell us (it is also nil when merely hidden from us).
    var isAssociated: Bool { powerOn && txRate > 0 && channel != nil }

    private static func bandName(_ b: CWChannelBand) -> String? {
        switch b {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return nil
        }
    }

    private static func widthName(_ w: CWChannelWidth) -> String? {
        switch w {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return w.rawValue == 5 ? "320 MHz" : nil
        }
    }

    private static func phyName(_ m: CWPHYMode) -> String? {
        switch m {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        case .modeNone: return nil
        @unknown default: return m.rawValue == 7 ? "802.11be" : nil
        }
    }

    private static func securityName(_ s: CWSecurity) -> String? {
        switch s {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .OWE: return "OWE"
        case .oweTransition: return "OWE Transition"
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}

/// Location authorization, which is what gates the SSID. Requested once at first launch
/// (the user opted in to this); the menu offers a retry/open-settings row if it was denied.
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus
    var onChange: (() -> Void)?

    private override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { status == .authorizedAlways || status == .authorized }
    var isDenied: Bool { status == .denied || status == .restricted }

    func requestIfNeeded() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            self.onChange?()
        }
    }

    /// Deep link to System Settings › Privacy & Security › Location Services.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
}
