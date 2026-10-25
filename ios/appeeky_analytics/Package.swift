// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "appeeky_analytics",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "appeeky-analytics", targets: ["appeeky_analytics"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "appeeky_analytics",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      linkerSettings: [
        .linkedFramework("StoreKit")
      ]
    )
  ]
)
