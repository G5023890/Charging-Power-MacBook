// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ChargingPowerMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ChargingPowerMenuBar",
            targets: ["ChargingPowerMenuBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ChargingPowerMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
