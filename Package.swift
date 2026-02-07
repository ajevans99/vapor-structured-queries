// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "vapor-structured-queries",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "VaporStructuredQueries",
      targets: ["VaporStructuredQueries"]
    ),
    .library(
      name: "VaporStructuredQueriesPostgresNIO",
      targets: ["VaporStructuredQueriesPostgresNIO"]
    ),
    .library(
      name: "VaporStructuredQueriesTestSupport",
      targets: ["VaporStructuredQueriesTestSupport"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    // .package(name: "swift-structured-queries", path: "../swift-structured-queries"),
    // .package(url: "https://github.com/pointfreeco/swift-structured-queries.git", from: "0.30.0"),
    .package(url: "https://github.com/ajevans99/swift-structured-queries.git", branch: "postgres"),
  ],
  targets: [
    .target(
      name: "VaporStructuredQueries",
      dependencies: [
        .product(name: "Vapor", package: "vapor"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "StructuredQueries", package: "swift-structured-queries"),
      ]
    ),
    .target(
      name: "VaporStructuredQueriesPostgresNIO",
      dependencies: [
        .target(name: "VaporStructuredQueries"),
        .product(name: "StructuredQueriesPostgresNIO", package: "swift-structured-queries"),
      ]
    ),
    .target(
      name: "VaporStructuredQueriesTestSupport",
      dependencies: [
        .target(name: "VaporStructuredQueries"),
        .product(name: "StructuredQueries", package: "swift-structured-queries"),
      ]
    ),
    .testTarget(
      name: "VaporStructuredQueriesTests",
      dependencies: [
        .target(name: "VaporStructuredQueries"),
        .target(name: "VaporStructuredQueriesPostgresNIO"),
        .target(name: "VaporStructuredQueriesTestSupport"),
        .product(name: "VaporTesting", package: "vapor"),
      ]
    ),
  ]
)
