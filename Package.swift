// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NimbusNetBar",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "NimbusNetBar", targets: ["NimbusNetBar"]),
    ],
    targets: [
        // The whole menu bar app. build.sh wraps the binary into NimbusNetBar.app.
        .executableTarget(
            name: "NimbusNetBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
