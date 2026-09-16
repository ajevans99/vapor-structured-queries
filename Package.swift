// swift-tools-version: 6.1
import PackageDescription

#if os(Linux)
  let sqlitePkgConfig: String? = "sqlite3"
#else
  let sqlitePkgConfig: String? = nil
#endif

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
    .library(
      name: "VaporStructuredQueriesSQLite",
      targets: ["VaporStructuredQueriesSQLite"]
    ),
  ],
  traits: [
    .trait(
      name: "FluentCompatibility",
      description: "Disable Fluent-colliding conveniences; use structuredQueries-prefixed APIs."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(
      url: "https://github.com/ajevans99/swift-structured-queries.git",
      revision: "181cf5ece309934ab85340e546777af3ddf8bb06"
    ),
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
    .target(
      name: "VaporStructuredQueriesSQLite",
      dependencies: [
        .target(name: "VaporStructuredQueries"),
        .target(name: "VaporStructuredQueriesCSQLite"),
        .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
      ]
    ),
    .systemLibrary(
      name: "VaporStructuredQueriesCSQLite",
      pkgConfig: sqlitePkgConfig,
      providers: [.apt(["libsqlite3-dev"])]
    ),
    .testTarget(
      name: "VaporStructuredQueriesTests",
      dependencies: [
        .target(name: "VaporStructuredQueries"),
        .target(name: "VaporStructuredQueriesPostgresNIO"),
        .target(name: "VaporStructuredQueriesSQLite"),
        .target(name: "VaporStructuredQueriesTestSupport"),
        .product(name: "VaporTesting", package: "vapor"),
      ]
    ),
  ]
)
