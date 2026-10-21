// swift-tools-version:5.9
// Package.swift
// DesktopPetForMacApp — Swift Package Manager 项目配置
// 使用 `swift build` 编译，或在 Xcode 中打开 Package.swift

import PackageDescription

let package = Package(
    name: "DesktopPetForMacApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "DesktopPetForMacApp",
            targets: ["DesktopPetForMacApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DesktopPetForMacApp",
            path: "DesktopPetForMacApp",
            // 以下资源由 package.sh 直接复制到 .app 的 Contents/Resources/，
            // 运行时经 Bundle.main/源码树 fallback 读取（不经过 Bundle.module），
            // 声明为 SPM 资源反而无效，exclude 掉以消除 "unhandled file" 警告
            exclude: [
                "Info.plist",
                "Resources/AppIcon.icns",
                "Resources/MenuBarIcon.png",
                "Resources/SpeechBubble.png",
                "Resources/Sprites"
            ],
            resources: [
                .copy("Resources/WordBank"),
                .copy("Resources/ProblemBank")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "DesktopPetForMacAppTests",
            dependencies: ["DesktopPetForMacApp"],
            path: "Tests"
        )
    ]
)
