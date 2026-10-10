// swift-tools-version:5.9
// Package.swift
// DesktopCat — Swift Package Manager 项目配置
// 使用 `swift build` 编译，或在 Xcode 中打开 Package.swift

import PackageDescription

let package = Package(
    name: "DesktopCat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "DesktopCat",
            targets: ["DesktopCat"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DesktopCat",
            path: "DesktopCat",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
