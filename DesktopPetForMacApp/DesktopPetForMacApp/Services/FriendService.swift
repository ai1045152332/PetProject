// FriendService.swift
// DesktopPetForMacApp — 好友与宠物消息客户端
// 与后端 /api/social/<action> 交互：注册取宠物号、加好友、列好友、删好友、发消息。
// 请求体统一用服务端公钥加密（含 deviceId 等敏感字段），与激活码/云端图片一致；
// 后端一律 HTTP 200，业务失败用信封 code≠0 + msg 回传，这里据此抛出本地化错误。

import Foundation

/// 好友条目：一只已添加的宠物
struct PetFriend: Equatable {
    let petNo: Int
    let petName: String
    /// 展示用文案：无名时回退「宠物 #号」
    var display: String {
        petName.isEmpty ? "宠物 #\(petNo)" : "\(petName) #\(petNo)"
    }
}

@MainActor
enum FriendService {
    /// 本机宠物号缓存键（由心跳响应或 register 接口写入）
    static let petNoKey = "settings.myPetNo"
    /// 宠物号变化通知（供设置面板刷新展示）
    static let petNoChanged = Notification.Name("FriendService.petNoChanged")

    /// 当前已知宠物号（0 表示尚未分配/同步）
    static var myPetNo: Int {
        UserDefaults.standard.integer(forKey: petNoKey)
    }

    /// 写入宠物号（仅在有效且变化时持久化并广播）
    static func setMyPetNo(_ value: Int) {
        guard value > 0, value != myPetNo else { return }
        UserDefaults.standard.set(value, forKey: petNoKey)
        NotificationCenter.default.post(name: petNoChanged, object: nil)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Friend", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 对外接口

    /// 注册/刷新本机宠物号（设备从未心跳时也能即时拿到），并写入本地缓存
    static func refreshMyPetNo() async throws -> Int {
        let data = try await post("register")
        let petNo = intVal(data?["petNo"])
        setMyPetNo(petNo)
        return petNo
    }

    /// 拉取好友列表
    static func listFriends() async throws -> [PetFriend] {
        let data = try await post("list")
        return decodeFriends(data?["friends"])
    }

    /// 加好友，返回添加后的完整好友列表
    static func addFriend(petNo: Int) async throws -> [PetFriend] {
        let data = try await post("add", payload: ["petNo": petNo])
        return decodeFriends(data?["friends"])
    }

    /// 删除好友，返回删除后的完整好友列表
    static func removeFriend(petNo: Int) async throws -> [PetFriend] {
        let data = try await post("remove", payload: ["petNo": petNo])
        return decodeFriends(data?["friends"])
    }

    /// 给好友发消息（落到对方云端收件箱，等其下次心跳拉取展示）
    static func sendMessage(toPetNo: Int, text: String) async throws {
        _ = try await post("send", payload: ["petNo": toPetNo, "text": text])
    }

    // MARK: - 私有

    /// 构造并发送一个加密 POST，返回响应里的 data 字典（业务失败会抛出 msg）
    private static func post(_ action: String, payload: [String: Any] = [:]) async throws -> [String: Any]? {
        let deviceId = AccessControl.deviceID
        guard deviceId != "unknown-device" else { throw failure("无法识别当前设备") }

        var body = payload
        body["deviceId"] = deviceId
        body["petName"] = PetName.currentName()

        guard let plain = try? JSONSerialization.data(withJSONObject: body),
              let encrypted = PayloadCrypto.encryptedEnvelope(plain) else {
            throw failure("本地加密失败")
        }
        guard let url = URL(string: ServerConfig.baseURL + "/api/social/" + action) else {
            throw failure("服务地址无效")
        }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encrypted

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw failure("服务器请求失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("响应解析失败")
        }
        let code = intVal(json["code"])
        if code != 0 {
            throw failure(json["msg"] as? String ?? "操作失败")
        }
        return json["data"] as? [String: Any]
    }

    private static func decodeFriends(_ raw: Any?) -> [PetFriend] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            let petNo = intVal(dict["petNo"])
            guard petNo > 0 else { return nil }
            return PetFriend(petNo: petNo, petName: dict["petName"] as? String ?? "")
        }
    }

    /// JSON 数字统一取 Int（NSNumber/Int/字符串都兼容）
    private static func intVal(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}
