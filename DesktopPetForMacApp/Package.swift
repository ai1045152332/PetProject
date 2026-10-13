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
            resources: [
                .copy("Resources/WordBank")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
