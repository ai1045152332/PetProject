import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PetImageRecord: Decodable {
    let id: String
    let name: String
    let state: String?
    let createdAt: String
    let status: String?
    let error: String?
    var isReady: Bool { status == nil || status == "ready" }
    var isGenerating: Bool { ["beautifying", "animating", "encoding"].contains(status ?? "") }
    var stageLabel: String {
        switch status {
        case "beautifying": return "正在提取并美化宠物…"
        case "animating": return "正在生成宠物动画帧…"
        case "encoding": return "正在合成 GIF…"
        case "failed": return "生成失败"
        default: return "可使用"
        }
    }
}
struct PetImageLibrary: Decodable {
    let currentId: String
    let images: [PetImageRecord]
    let currentIds: [String: String]?
    let selectionVersion: Int?
    // Lifetime AI generation budget for the active code, shared across its bound devices.
    let generationLimit: Int?
    let generationRemaining: Int?

    func currentID(for state: CatAnimationState) -> String {
        currentIds?[state.rawValue] ?? currentId
    }
    func history(for state: CatAnimationState) -> [PetImageRecord] {
        images.filter { $0.state == nil || $0.state == "" || $0.state == state.rawValue }
    }
    var selections: [String: String] {
        // States absent from the server are left untouched, preserving existing local uploads.
        var result = currentIds ?? [:]
        if !currentId.isEmpty || (selectionVersion ?? 0) > 0 {
            for state in CatAnimationState.allCases where result[state.rawValue] == nil {
                result[state.rawValue] = currentId
            }
        }
        return result
    }
}

@MainActor
enum PetImageService {
    struct Envelope: Decodable { let data: PetImageLibrary }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PetImages", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func credentials(id: String = "", stateValue: String = "") throws -> Data {
        guard let code = AccessControl.serverActivationCode else {
            throw failure("请先在通用设置中使用有效的服务端激活码解锁；本地快捷码不支持云端图片。")
        }
        guard AccessControl.deviceID != "unknown-device" else { throw failure("无法识别当前设备") }
        let plain = try JSONSerialization.data(withJSONObject: ["code": code, "deviceId": AccessControl.deviceID, "id": id, "state": stateValue])
        guard let encrypted = PayloadCrypto.encryptedEnvelope(plain) else { throw failure("授权信息加密失败") }
        return encrypted
    }
    static func request(_ action: String, id: String = "", stateValue: String = "", upload: (Data, String)? = nil) async throws -> Data {
        let identity = AccessControl.serverActivationCode
        let auth = try credentials(id: id, stateValue: stateValue)
        var request = URLRequest(url: URL(string: ServerConfig.baseURL + "/api/pet-images/" + action)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        if let (data, name) = upload {
            let boundary = "Pet-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func append(_ text: String) { body.append(Data(text.utf8)) }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"auth\"\r\n\r\n")
            body.append(auth)
            append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            body.append(data)
            append("\r\n--\(boundary)--\r\n")
            request.httpBody = body
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = auth
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw failure(json?["msg"] as? String ?? "服务器请求失败")
        }
        // An activation may be cleared or replaced while the network request is running.
        guard identity == AccessControl.serverActivationCode else { throw failure("授权已变化，请重试") }
        return data
    }
    static func library() async throws -> PetImageLibrary {
        try JSONDecoder().decode(Envelope.self, from: await request("list")).data
    }
    static func select(_ id: String, for state: CatAnimationState) async throws -> PetImageLibrary {
        try JSONDecoder().decode(Envelope.self, from: await request("select", id: id, stateValue: state.rawValue)).data
    }
    /// Reads and validates a local PNG/JPEG file for cloud upload (size and pixel bounds).
    /// Keep the original pixels and alpha; only the displayed image is scaled.
    static func validatedImageFile(_ url: URL, allowsGIF: Bool = false) throws -> (Data, String) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 10 * 1024 * 1024 else { throw failure("图片不得超过 10 MB") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              ([UTType.png.identifier, UTType.jpeg.identifier].contains(type as String)
                || (allowsGIF && type as String == UTType.gif.identifier)),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 40_000_000 else {
            throw failure(allowsGIF ? "请选择有效的 PNG/JPEG/GIF 图片，像素不得超过 4000 万" : "请选择有效的 PNG/JPEG 图片，像素不得超过 4000 万")
        }
        let name = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        return (data, name)
    }
    static func upload(_ url: URL, for state: CatAnimationState?) async throws -> PetImageLibrary {
        let (data, name) = try validatedImageFile(url)
        return try JSONDecoder().decode(Envelope.self, from: await request("upload", stateValue: state?.rawValue ?? "", upload: (data, name))).data
    }
    /// Uploads one photo and asks the server to fan it out into one generated image per state.
    /// The whole batch costs a single quota unit and is generated sequentially on the server.
    static func uploadAllStates(_ url: URL) async throws -> PetImageLibrary {
        let (data, name) = try validatedImageFile(url)
        return try JSONDecoder().decode(Envelope.self, from: await request("upload", stateValue: "all", upload: (data, name))).data
    }
    static func retry(_ id: String, for state: CatAnimationState) async throws -> PetImageLibrary {
        try JSONDecoder().decode(Envelope.self, from: await request("retry", id: id, stateValue: state.rawValue)).data
    }
    static func waitForGeneration(_ id: String, initial: PetImageLibrary,
                                  progress: ((String) -> Void)? = nil) async throws -> PetImageLibrary {
        var library = initial
        // Jobs continue on the server if the app closes or this polling task is cancelled.
        for _ in 0..<200 {
            try Task.checkCancellation()
            guard let item = library.images.first(where: { $0.id == id }) else { throw failure("生成记录不存在") }
            if item.isReady { return library }
            if item.status == "failed" { throw failure(item.error ?? "生成失败，可在历史图片中重试") }
            progress?(item.stageLabel)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            library = try await self.library()
        }
        throw failure("等待生成超时，任务可能仍在服务器运行，请稍后打开历史图片查看。")
    }
    /// Waits until every one of `ids` leaves the generating state (ready or failed). Unlike the
    /// single-id helper this never throws on an individual failure: the returned library carries each
    /// record's own status so the caller can apply the states that succeeded and report the rest.
    static func waitForGeneration(_ ids: [String], initial: PetImageLibrary,
                                  progress: ((String) -> Void)? = nil) async throws -> PetImageLibrary {
        var library = initial
        for _ in 0..<400 {
            try Task.checkCancellation()
            let pending = library.images.filter { ids.contains($0.id) && $0.isGenerating }
            if pending.isEmpty { return library }
            progress?(pending.first?.stageLabel ?? "正在逐状态生成…")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            library = try await self.library()
        }
        throw failure("等待生成超时，任务可能仍在服务器运行，请稍后打开历史图片查看。")
    }
    static func image(_ id: String) async throws -> Data {
        // 本地已有（之前应用过或预览过并落盘）直接复用，命中即免一次远程取图。
        if let cached = CustomSpriteStore.cachedCloudImage(id: id) { return cached }
        let data = try await request("content", id: id)
        CustomSpriteStore.cacheCloudImage(id: id, data: data)
        return data
    }
}
