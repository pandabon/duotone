// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "Duotone",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DuotoneCore", targets: ["DuotoneCore"])
  ],
  targets: [
    .target(name: "DuotoneCore", path: "Sources/DuotoneCore"),
    .executableTarget(name: "Duotone", dependencies: ["DuotoneCore"], path: "Sources/Duotone"),
    .testTarget(name: "DuotoneCoreTests", dependencies: ["DuotoneCore"], path: "Tests/DuotoneCoreTests")
  ],
  swiftLanguageModes: [.v6]
)
