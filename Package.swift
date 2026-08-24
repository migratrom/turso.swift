// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "turso-swift",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
  ],
  products: [
    .library(name: "Turso", targets: ["Turso"])
  ],
  targets: [
    .binaryTarget(
      name: "CTurso",
      path: "Vendor/CTurso.xcframework"
    ),
    .target(
      name: "Turso",
      dependencies: ["CTurso"],
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
        .linkedLibrary("resolv"),
      ]
    ),
    .testTarget(
      name: "TursoTests",
      dependencies: ["Turso"]
    ),
  ]
)
