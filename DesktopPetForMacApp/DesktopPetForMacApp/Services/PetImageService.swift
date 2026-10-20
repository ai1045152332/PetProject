import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PetImageRecord: Decodable {
    let id: String
    let name: String
    let createdAt: String
}
struct PetImageLibrary: Decodable {
    let currentId: String
    let images: [PetImageRecord]
}

@MainActor
enum PetImageService {
    struct Envelope: Decodable { let data: PetImageLibrary }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PetImages", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func credentials(id: String = "") throws -> Data {
        guard let code = AccessControl.serverActivationCode else {
            throw failure("请先在通用设置中使用有效的服务端激活码解锁；本地快捷码不支持云端图片。")
        }
        guard AccessControl.deviceID != "unknown-device" else { throw failure("无法识别当前设备") }
        let plain = try JSONSerialization.data(withJSONObject: ["code": code, "deviceId": AccessControl.deviceID, "id": id])
        guard let encrypted = PayloadCrypto.encryptedEnvelope(plain) else { throw failure("授权信息加密失败") }
        return encrypted
    }
    static func request(_ action: String, id: String = "", upload: (Data, String)? = nil) async throws -> Data {
        let identity = AccessControl.serverActivationCode
        let auth = try credentials(id: id)
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
    static func select(_ id: String) async throws -> PetImageLibrary {
        try JSONDecoder().decode(Envelope.self, from: await request("select", id: id)).data
    }
    static func upload(_ url: URL) async throws -> PetImageLibrary {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 10 * 1024 * 1024 else { throw failure("图片不得超过 10 MB") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 40_000_000 else {
            throw failure("请选择有效的 PNG/JPEG 图片，像素不得超过 4000 万")
        }
        // Keep the original pixels and alpha; only the displayed image is scaled.
        let name = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        return try JSONDecoder().decode(Envelope.self, from: await request("upload", upload: (data, name))).data
    }
    static func image(_ id: String) async throws -> Data {
        try await request("content", id: id)
    }
}
