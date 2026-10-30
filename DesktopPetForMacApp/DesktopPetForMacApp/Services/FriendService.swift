// FriendService.swift
// DesktopPetForMacApp — 好友与宠物消息客户端
// 与后端 /api/social/<action> 交互：注册取宠物号、发好友申请、同意/拒绝、列好友、删好友、发消息、确认已读、回看聊天记录。
// 加好友需对方同意：add 只发申请，对方 accept 后双方才互为好友；
// 消息卡关闭时调 read 上报，服务端据此标记已读（未确认前会重投几次）；
// 聊天窗用 history 拉与某位好友的往来留痕（仅双方互为好友时开放）。
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

/// 收到的好友申请（等待本机同意/拒绝）
struct PetFriendRequest: Equatable {
    let id: String
    let fromPetNo: Int
    let fromName: String
    /// 展示用文案：无名时回退「宠物 #号」
    var display: String {
        fromName.isEmpty ? "宠物 #\(fromPetNo)" : "\(fromName) #\(fromPetNo)"
    }
}

/// 聊天窗的一行消息：好友往来留痕的展示视图
/// 来源有两处——心跳下发的待展示消息（只有正文、无时间），与 history 回看的服务端留痕（带时间与已读状态）
struct PetChatMessage: Equatable {
    let id: String
    let fromPetNo: Int
    let fromName: String
    let text: String
    /// 发送时间（心跳下发的消息不带时间，nil 时气泡不显示时刻）
    let sentAt: Date?
    /// 对方是否已读（只对本机发出的那条有意义）
    let isRead: Bool
}

/// 发好友申请的结果
enum FriendRequestOutcome {
    /// 已发出，等对方同意
    case pending
    /// 已互为好友（双方都申请过，或本就已是好友）
    case mutual

    /// 给用户的提示文案
    var notice: String {
        switch self {
        case .pending: return "申请已发出，对方同意后你们就是好友了"
        case .mutual: return "你们已互为好友"
        }
    }
}

@MainActor
enum FriendService {
    /// 本机宠物号缓存键（由心跳响应或 register 接口写入）
    static let petNoKey = "settings.myPetNo"
    /// 已弹过卡的好友申请 ID（避免心跳每分钟重复下发时反复弹卡）
    static let shownRequestIDsKey = "settings.shownFriendRequestIDs"
    /// 宠物号变化通知（供设置面板刷新展示）
    static let petNoChanged = Notification.Name("FriendService.petNoChanged")
    /// 好友关系变化通知（同意后卡片与设置面板列表都要刷新）
    static let friendsChanged = Notification.Name("FriendService.friendsChanged")

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

    /// 发起好友申请（需对方同意）；返回自己的好友列表与申请结果
    static func requestFriend(petNo: Int) async throws -> (friends: [PetFriend], outcome: FriendRequestOutcome) {
        let data = try await post("add", payload: ["petNo": petNo])
        let status = data?["status"] as? String ?? ""
        return (decodeFriends(data?["friends"]), status == "mutual" ? .mutual : .pending)
    }

    /// 拉取发给本机、待处理的好友申请
    static func pendingRequests() async throws -> [PetFriendRequest] {
        let data = try await post("requests")
        return decodeRequests(data?["requests"])
    }

    /// 同意某宠物号的好友申请：成功后双方互为好友
    static func acceptRequest(fromPetNo: Int) async throws -> [PetFriend] {
        let friends = try await decideRequest("accept", fromPetNo: fromPetNo)
        NotificationCenter.default.post(name: friendsChanged, object: nil)
        return friends
    }

    /// 拒绝对方的好友申请（不建立好友关系）
    static func rejectRequest(fromPetNo: Int) async throws -> [PetFriend] {
        let friends = try await decideRequest("reject", fromPetNo: fromPetNo)
        NotificationCenter.default.post(name: friendsChanged, object: nil)
        return friends
    }

    /// 看完消息关卡时确认已读（尽力而为：失败不影响本地，服务端稍后会重投）
    static func confirmRead(ids: [String]) async {
        guard !ids.isEmpty else { return }
        _ = try? await post("read", payload: ["ids": ids])
    }

    /// 记录已弹过卡的申请 ID，返回其中尚未弹过的（首次见到的才需要弹卡）
    static func markRequestsShown(_ requests: [PetFriendRequest]) -> [PetFriendRequest] {
        let defaults = UserDefaults.standard
        var shown = (defaults.stringArray(forKey: shownRequestIDsKey) ?? [])
        var shownSet = Set(shown)
        var fresh: [PetFriendRequest] = []
        for req in requests where !shownSet.contains(req.id) {
            fresh.append(req)
            shownSet.insert(req.id)
            shown.append(req.id)
        }
        if !fresh.isEmpty {
            // 只保留最近 200 个 ID，避免无限增长
            defaults.set(Array(shown.suffix(200)), forKey: shownRequestIDsKey)
        }
        return fresh
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

    /// 拉取与某位好友的最近聊天记录（旧 → 新）；服务端要求双方已互加好友
    static func conversationHistory(with petNo: Int) async throws -> [PetChatMessage] {
        let data = try await post("history", payload: ["petNo": petNo])
        return decodeChatMessages(data?["messages"])
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

    /// 同意/拒绝的共用调用：服务端回传处理后的好友列表
    private static func decideRequest(_ action: String, fromPetNo: Int) async throws -> [PetFriend] {
        let data = try await post(action, payload: ["petNo": fromPetNo])
        return decodeFriends(data?["friends"])
    }

    private static func decodeRequests(_ raw: Any?) -> [PetFriendRequest] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            let petNo = intVal(dict["fromPetNo"])
            let id = dict["id"] as? String ?? ""
            guard petNo > 0, !id.isEmpty else { return nil }
            return PetFriendRequest(id: id, fromPetNo: petNo, fromName: dict["fromName"] as? String ?? "")
        }
    }

    private static func decodeFriends(_ raw: Any?) -> [PetFriend] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            let petNo = intVal(dict["petNo"])
            guard petNo > 0 else { return nil }
            return PetFriend(petNo: petNo, petName: dict["petName"] as? String ?? "")
        }
    }

    /// 聊天留痕解码：服务端时间给 UnixMilli，0（含缺失）视为「没有时间」，气泡不显示时刻
    private static func decodeChatMessages(_ raw: Any?) -> [PetChatMessage] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            let fromPetNo = intVal(dict["fromPetNo"])
            let text = dict["text"] as? String ?? ""
            guard fromPetNo > 0, !text.isEmpty else { return nil }
            let sentMs = intVal(dict["sentMs"])
            return PetChatMessage(
                id: dict["id"] as? String ?? "",
                fromPetNo: fromPetNo,
                fromName: dict["fromName"] as? String ?? "",
                text: text,
                sentAt: sentMs > 0 ? Date(timeIntervalSince1970: Double(sentMs) / 1000) : nil,
                isRead: intVal(dict["readMs"]) > 0
            )
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
