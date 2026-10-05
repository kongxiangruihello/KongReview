// swift-tools-version: 5.9
// KongGleanCore：与界面、数据库无关的纯逻辑层（模型、回顾算法、导出、捕获链接解析）。
// 可在命令行单独测试：cd Packages/KongGleanCore && swift test

import PackageDescription

let package = Package(
    name: "KongGleanCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KongGleanCore", targets: ["KongGleanCore"]),
    ],
    targets: [
        .target(name: "KongGleanCore"),
        .testTarget(name: "KongGleanCoreTests", dependencies: ["KongGleanCore"]),
    ]
)
