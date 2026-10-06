// swift-tools-version: 5.9
// KongReviewCore：与界面、数据库无关的纯逻辑层（模型、回顾算法、导出、捕获链接解析）。
// 可在命令行单独测试：cd Packages/KongReviewCore && swift test

import PackageDescription

let package = Package(
    name: "KongReviewCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KongReviewCore", targets: ["KongReviewCore"]),
    ],
    targets: [
        .target(name: "KongReviewCore"),
        .testTarget(name: "KongReviewCoreTests", dependencies: ["KongReviewCore"]),
    ]
)
