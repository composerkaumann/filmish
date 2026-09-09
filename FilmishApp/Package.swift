// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FilmishApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Filmish", targets: ["Filmish"])
    ],
    targets: [
        .executableTarget(
            name: "Filmish",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilmishTests",
            dependencies: ["Filmish"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
