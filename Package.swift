// swift-tools-version: 5.9
// 用于不装 Xcode、只用“命令行工具”构建 App 与 DMG（见 Tools/build-dmg.sh）。
// 用 Xcode 开发时仍以 project.yml（XcodeGen）为准，两者共用同一套源码。

import PackageDescription

let package = Package(
    name: "KongReview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KongReview", targets: ["KongReview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(path: "Packages/KongReviewCore"),
    ],
    targets: [
        .executableTarget(
            name: "KongReview",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KongReviewCore", package: "KongReviewCore"),
            ],
            path: "KongReview",
            exclude: ["Resources"]
        ),
    ]
)
