// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Zhiding",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Zhiding", targets: ["Zhiding"]),
        .executable(name: "ZhidingChecks", targets: ["ZhidingChecks"])
    ],
    targets: [
        .target(name: "ZhidingCore"),
        .executableTarget(name: "Zhiding", dependencies: ["ZhidingCore"]),
        // 使用无 XCTest 依赖的检查程序，兼容仅安装 Command Line Tools 的环境。
        .executableTarget(name: "ZhidingChecks", dependencies: ["ZhidingCore"], path: "Tests/ZhidingChecks")
    ]
)
