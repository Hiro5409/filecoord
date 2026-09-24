// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "filecoord",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "filecoord", targets: ["filecoord"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser.git",
      exact: "1.8.2"
    )
  ],
  targets: [
    .executableTarget(
      name: "filecoord",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "FileCoordTests",
      dependencies: ["filecoord"]
    ),
  ]
)
