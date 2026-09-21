// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "WeChatTweak",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "wechattweak",
            targets: [
                "WeChatTweak"
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0")
    ],
    targets: [
        .executableTarget(
            name: "WeChatTweak",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: ".",
            exclude: ["Runtime", "Tests", "README.md", "Makefile", "LICENSE", "CNAME", "_config.yml", "Package.resolved"],
            sources: ["Sources/WeChatTweak"],
            resources: [.copy("config.json")]
        ),
        .testTarget(name: "WeChatTweakTests", dependencies: ["WeChatTweak"], path: "Tests/WeChatTweakTests")
    ]
)
