import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import DesktopPetForMacApp

final class PetAnimationTests: XCTestCase {
    func testGIFDecodesDistinctFramesWithDurationsAndTransparency() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for (index, delay) in [0.1, 0.2].enumerated() {
            let space = CGColorSpaceCreateDeviceRGB()
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: index == 1 ? 1 : 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let animation = try XCTUnwrap(CustomSpriteStore.decodeAnimation(data as Data))
        XCTAssertEqual(animation.frames.count, 2)
        XCTAssertEqual(animation.durations[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(animation.durations[1], 0.2, accuracy: 0.001)
        let first = try XCTUnwrap(animation.frames[0].tiffRepresentation)
        let second = try XCTUnwrap(animation.frames[1].tiffRepresentation)
        XCTAssertNotEqual(first, second)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: first))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
        XCTAssertEqual(bitmap.pixelsWide, 32)
    }
    func testCorruptAnimationIsRejected() {
        XCTAssertNil(CustomSpriteStore.decodeAnimation(Data("broken GIF".utf8)))
    }

    private func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testStateCachesResetAndLegacyUploadsRemainIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        // The upload location from the original application already stored independent state files.
        try image.write(to: directory.appendingPathComponent("sleep.png"))
        let focusID = String(repeating: "a", count: 32)
        try CustomSpriteStore.installCloudImages(selections: ["focus": focusID], images: [focusID: image], directory: directory)
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .focus, directory: directory))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .sleep, directory: directory))
        XCTAssertNil(CustomSpriteStore.loadAnimation(for: .pet, directory: directory))
        try CustomSpriteStore.installCloudImages(selections: ["focus": ""], images: [:], directory: directory)
        XCTAssertNil(CustomSpriteStore.loadAnimation(for: .focus, directory: directory))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .sleep, directory: directory))
        // Resetting a state must also block a legacy shared cache from showing through.
        try image.write(to: directory.appendingPathComponent("current.png"))
        XCTAssertNil(CustomSpriteStore.loadAnimation(for: .focus, directory: directory))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .idel, directory: directory))
        let sleepID = String(repeating: "b", count: 32)
        XCTAssertThrowsError(try CustomSpriteStore.installCloudImages(selections: ["sleep": sleepID], images: [sleepID: Data()], directory: directory))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .sleep, directory: directory))
    }
    func testCloudLibraryFiltersHistoryAndPreservesLegacySelection() throws {
        let json = Data(#"{"currentId":"legacy","currentIds":{"focus":"focus-id","pet":""},"images":[{"id":"legacy","name":"old","createdAt":"date"},{"id":"focus-id","state":"focus","name":"focus","createdAt":"date","status":"ready"},{"id":"sleep-id","state":"sleep","name":"sleep","createdAt":"date","status":"ready"}]}"#.utf8)
        let library = try JSONDecoder().decode(PetImageLibrary.self, from: json)
        XCTAssertEqual(library.currentID(for: .focus), "focus-id")
        XCTAssertEqual(library.currentID(for: .pet), "")
        XCTAssertEqual(library.currentID(for: .sleep), "legacy")
        XCTAssertEqual(library.history(for: .focus).map(\.id), ["legacy", "focus-id"])
        XCTAssertEqual(library.selections["pet"], "")
        let empty = try JSONDecoder().decode(PetImageLibrary.self, from: Data(#"{"currentId":"","images":[]}"#.utf8))
        XCTAssertTrue(empty.selections.isEmpty, "An unused cloud library must preserve existing local state images")
    }

    /// 服务端历史数据可能残留已移除状态的选中（如旧 warn 状态），安装时应跳过而非报错。
    func testInstallCloudImagesSkipsUnknownLegacyStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        let focusID = String(repeating: "a", count: 32)
        let warnID = String(repeating: "d", count: 32)
        try CustomSpriteStore.installCloudImages(
            selections: ["focus": focusID, "warn": warnID],
            images: [focusID: image, warnID: image], directory: directory)
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .focus, directory: directory))
        let manifest = directory.appendingPathComponent("cloud-selections.json")
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        XCTAssertNil(saved["warn"], "Unknown legacy state must not be written into the manifest")
    }

    /// 共享图（一次 AI 生成、无单状态选中）应展开覆盖全部 5 个状态。
    func testSharedImageSelectionExpandsToAllStates() throws {
        let sharedID = String(repeating: "c", count: 32)
        let json = Data(#"{"currentId":"""# + sharedID + #"","images":[{"id":"""# + sharedID + #"","name":"shared","createdAt":"date","status":"ready"}]}"#.utf8)
        let library = try JSONDecoder().decode(PetImageLibrary.self, from: json)
        for state in CatAnimationState.allCases {
            XCTAssertEqual(library.selections[state.rawValue], sharedID, "Shared image must cover \(state.displayName)")
        }
    }

    /// 本地直传优先级最高：写入后覆盖云端/legacy 图，移除后按原顺序回退。
    func testLocalDirectUploadTakesPriorityAndFallsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        // Legacy shared upload remains readable through the local namespace.
        try image.write(to: directory.appendingPathComponent("current.png"))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .idel, directory: directory))
        try CustomSpriteStore.installLocalImage(image, for: .idel, directory: directory)
        XCTAssertTrue(CustomSpriteStore.hasLocalImage(for: .idel))

        // A cloud manifest selection must not shadow the local direct upload.
        let focusID = String(repeating: "a", count: 32)
        try CustomSpriteStore.installCloudImages(selections: ["focus": focusID, "idel": focusID], images: [focusID: image], directory: directory)
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .idel, directory: directory))

        // Removing the local image falls the state back to the cloud selection, other states keep both layers.
        try CustomSpriteStore.removeLocalImage(for: .idel, directory: directory)
        XCTAssertFalse(CustomSpriteStore.hasLocalImage(for: .idel))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .idel, directory: directory))
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .focus, directory: directory))
        // An explicit reset still blocks the legacy shared image (existing product semantics).
        try CustomSpriteStore.installCloudImages(selections: ["idel": ""], images: [:], directory: directory)
        XCTAssertNil(CustomSpriteStore.loadAnimation(for: .idel, directory: directory))
    }

    /// 本地直传接受多帧 GIF（带帧时长），拒绝损坏数据。
    func testLocalDirectUploadAcceptsAnimatedGIFAndRejectsCorruptData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for delay in [0.1, 0.2] {
            let space = CGColorSpaceCreateDeviceRGB()
            let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                bytesPerRow: 64, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 2, y: 2, width: 12, height: 12))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try CustomSpriteStore.installLocalImage(data as Data, for: .pet, directory: directory)
        let animation = try XCTUnwrap(CustomSpriteStore.loadAnimation(for: .pet, directory: directory))
        XCTAssertEqual(animation.frames.count, 2)
        XCTAssertEqual(animation.durations[1], 0.2, accuracy: 0.001)
        XCTAssertThrowsError(try CustomSpriteStore.installLocalImage(Data("broken GIF".utf8), for: .pet, directory: directory))
    }

    /// AI 图的状态归属独立落盘：换图/取消选中后仍能按状态分类，删除时同步清理。
    func testCloudImageOwnershipSurvivesSelectionChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        let focusID = String(repeating: "a", count: 32)
        let sleepID = String(repeating: "b", count: 32)
        try CustomSpriteStore.installCloudImages(selections: ["focus": focusID], images: [focusID: image], directory: directory)
        try CustomSpriteStore.installCloudImages(selections: ["sleep": sleepID], images: [sleepID: image], directory: directory)
        XCTAssertEqual(CustomSpriteStore.cloudStates(in: directory)[focusID], "focus")
        XCTAssertEqual(CustomSpriteStore.cloudStates(in: directory)[sleepID], "sleep")
        // 把休闲状态的图应用到睡觉状态：选中关系变了，生成状态归属不变。
        try CustomSpriteStore.selectLocalImage(key: "cloud:" + focusID, for: .sleep, directory: directory)
        XCTAssertEqual(CustomSpriteStore.cloudStates(in: directory)[focusID], "focus")
        let focusItem = try XCTUnwrap(CustomSpriteStore.localImages(directory: directory).first { $0.key == "cloud:" + focusID })
        XCTAssertEqual(focusItem.boundState, .focus)
        XCTAssertEqual(focusItem.selectedStates, [.sleep])
        // 直传图的归属固定为它自己的状态。
        try CustomSpriteStore.installLocalImage(image, for: .pet, directory: directory)
        let direct = try XCTUnwrap(CustomSpriteStore.localImages(directory: directory).first { $0.isDirect })
        XCTAssertEqual(direct.boundState, .pet)
        // 删除 AI 图后归属记录同样清掉，避免残留成“未归属”。
        try CustomSpriteStore.removeLocalImage(key: "cloud:" + focusID, directory: directory)
        XCTAssertNil(CustomSpriteStore.cloudStates(in: directory)[focusID])
        XCTAssertNil(CustomSpriteStore.localImages(directory: directory).first { $0.key == "cloud:" + focusID })
    }

    /// 老版本只存了选中清单：首次枚举时按选中回填归属，之后即使取消选中也保持分类。
    func testLegacyCloudImageInfersOwnershipOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        let legacyID = String(repeating: "c", count: 32)
        let orphanID = String(repeating: "d", count: 32)
        try image.write(to: directory.appendingPathComponent("cloud-\(legacyID).img"))
        try image.write(to: directory.appendingPathComponent("cloud-\(orphanID).img"))
        try JSONEncoder().encode(["idel": legacyID]).write(to: directory.appendingPathComponent("cloud-selections.json"), options: .atomic)
        let items = CustomSpriteStore.localImages(directory: directory)
        XCTAssertEqual(items.first { $0.key == "cloud:" + legacyID }?.boundState, .idel)
        XCTAssertNil(items.first { $0.key == "cloud:" + orphanID }?.boundState, "Neither selected nor recorded belongs to no state")
        XCTAssertEqual(CustomSpriteStore.cloudStates(in: directory)[legacyID], "idel")
        // 回填持久化：取消选中后依然归在休闲下（历史图片分类不会因换图而丢失）。
        try CustomSpriteStore.installCloudImages(selections: ["idel": ""], images: [:], directory: directory)
        XCTAssertEqual(CustomSpriteStore.localImages(directory: directory).first { $0.key == "cloud:" + legacyID }?.boundState, .idel)
    }

    /// 服务端图片 ID 已从 32 位 hex 换成“可读名-8 位 hex”，新格式必须能安装与读取；
    /// 带路径分隔符/前导点/长度不符的 ID 仍必须拒绝（ID 会拼进本机文件名）。
    func testReadableImageIDsInstallAndUnsafeIDsStayRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        let id = "my_cat-1a2b3c4d"
        try CustomSpriteStore.installCloudImages(selections: ["focus": id], images: [id: image], directory: directory)
        XCTAssertNotNil(CustomSpriteStore.loadAnimation(for: .focus, directory: directory))
        XCTAssertNotNil(CustomSpriteStore.cachedCloudImage(id: id, directory: directory), "Readable ID must hit the local cache")
        let cjkID = "微信图片20261026151149159-d54d2fdf"
        CustomSpriteStore.cacheCloudImage(id: cjkID, data: image, directory: directory)
        XCTAssertNotNil(CustomSpriteStore.cachedCloudImage(id: cjkID, directory: directory), "CJK label must stay usable")
        for unsafe in ["../etc/passwd", ".hidden-1a2b3c4d", "cat/1a2b3c4d", "cat-1a2b3c4", "cat"] {
            XCTAssertThrowsError(
                try CustomSpriteStore.installCloudImages(selections: ["focus": unsafe], images: [unsafe: image], directory: directory),
                "unsafe id \(unsafe) must be rejected")
        }
    }

    /// 服务端记录只补本机缺失的归属：已有归属不被覆盖，本机无文件的记录不写入。
    func testServerRecordsBackfillMissingOwnershipOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData()
        let focusID = "cat-11111111"
        let orphanID = "cat-22222222"
        try CustomSpriteStore.installCloudImages(selections: ["focus": focusID], images: [focusID: image], directory: directory)
        try image.write(to: directory.appendingPathComponent("cloud-\(orphanID).img"))
        XCTAssertTrue(CustomSpriteStore.mergeCloudStates([focusID: "sleep", orphanID: "pet", "remote-33333333": "idel"], directory: directory))
        let states = CustomSpriteStore.cloudStates(in: directory)
        XCTAssertEqual(states[focusID], "focus", "Existing ownership must win over a server record")
        XCTAssertEqual(states[orphanID], "pet")
        XCTAssertNil(states["remote-33333333"], "Records without a local file are skipped")
        XCTAssertFalse(CustomSpriteStore.mergeCloudStates([focusID: "sleep"], directory: directory), "Nothing new to write")
    }
}
