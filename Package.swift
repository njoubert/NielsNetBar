// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NielsNetBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "NielsNetBar", targets: ["NielsNetBar"]),
    ],
    targets: [
        // The whole menu bar app. build.sh wraps the binary into NielsNetBar.app.
        .executableTarget(
            name: "NielsNetBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
