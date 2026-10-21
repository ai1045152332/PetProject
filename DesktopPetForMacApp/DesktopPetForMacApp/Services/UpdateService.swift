// UpdateService.swift
// DesktopPetForMacApp — 客户端自动更新
// 流程：检查版本 → 提示 → 下载安装包 → 校验 sha256 + Ed25519 验签 → 换包重启
// 安全模型：App 只持有公钥，私钥离线保存在发布者本机（~/.cute-pet-release）

import Foundation
import CryptoKit
import AppKit

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    /// 发布签名公钥（Ed25519 raw 32 字节 base64，与发布脚本私钥对应）
    private let releasePublicKeyBase64 = "JeaR8M5ddeR67FkgsD+F2f3TNYRuAv5YRrJzTkaDWP0="

    /// 自动检查间隔：24 小时
    private let checkInterval: TimeInterval = 24 * 3600

    private var timer: Timer?
    private var checking = false
    private var downloading = false

    private init() {}

    /// 启动自动检查（启动 30 秒后首次检查，之后每 24 小时一次）
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkForUpdate(userInitiated: false)
        }
        let t = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdate(userInitiated: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 检查更新

    /// 定时自检：版本更新检查 + 授权复核（同一节奏）
    /// 检查更新
    /// - Parameters:
    ///   - userInitiated: 用户主动触发（无更新/失败时会弹提示）
    ///   - completion: 检查请求结束后的回调（用于恢复按钮等 UI 状态）
    func checkForUpdate(userInitiated: Bool, completion: (() -> Void)? = nil) {
        guard !checking, !downloading else {
            completion?()
            return
        }
        checking = true

        // 顺带向服务端复核授权：仅当服务端明确判定激活码失效时才收回权限
        AccessControl.revalidate { result in
            if result == .revoked {
                self.showAlert(title: "激活码已失效",
                               text: "该激活码已过期或被停用，高级功能已锁定。\n如需继续使用，请联系客服获取新的激活码。")
            }
        }

        guard let url = URL(string: ServerConfig.baseURL + "/api/app/latest") else {
            checking = false
            completion?()
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.checking = false
                completion?()
                self.handleCheckResult(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleCheckResult(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        if let error {
            FileLogger.log("[Update] 检查更新失败: \(error.localizedDescription)")
            if userInitiated { showAlert(title: "检查更新失败", text: "网络好像不太稳定，稍后再试试") }
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["data"] as? [String: Any],
              let remoteVersion = info["version"] as? String else {
            if userInitiated { showAlert(title: "已经是最新版本", text: "有新版本时小猫会第一时间告诉你") }
            return
        }

        guard Self.isNewer(remoteVersion, than: AppVersion.current) else {
            FileLogger.log("[Update] 已是最新版本 \(AppVersion.current)")
            if userInitiated { showAlert(title: "已经是最新版本", text: "有新版本时小猫会第一时间告诉你") }
            return
        }

        promptAndDownload(version: remoteVersion, notes: (info["notes"] as? String) ?? "", info: info)
    }

    // MARK: - 提示与下载

    private func promptAndDownload(version: String, notes: String, info: [String: Any]) {
        let alert = NSAlert()
        alert.messageText = "有新版本啦 \(version)"
        alert.informativeText = notes.isEmpty ? "要不要现在就更新？" : notes
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        download(info: info, version: version)
    }

    private func download(info: [String: Any], version: String) {
        guard let file = info["file"] as? String,
              let expectedSHA = info["sha256"] as? String,
              let signature = info["signature"] as? String,
              let url = URL(string: ServerConfig.baseURL + "/download/\(file)") else {
            showAlert(title: "更新失败", text: "更新信息不完整，请稍后再试")
            return
        }

        downloading = true
        FileLogger.log("[Update] 开始下载 \(file)")

        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.downloading = false }

                guard let tempURL, error == nil else {
                    FileLogger.log("[Update] 下载失败: \(error?.localizedDescription ?? "未知错误")")
                    self.showAlert(title: "更新下载失败", text: "网络好像不太稳定，稍后再试试")
                    return
                }
                guard let data = try? Data(contentsOf: tempURL) else {
                    self.showAlert(title: "更新失败", text: "安装包读取失败，请稍后再试")
                    return
                }

                // 1) 校验 sha256
                let actualSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actualSHA.lowercased() == expectedSHA.lowercased() else {
                    FileLogger.log("[Update] 摘要不匹配，拒绝更新")
                    self.showAlert(title: "更新失败", text: "安装包可能不完整，请稍后再试")
                    return
                }

                // 2) Ed25519 验签（签名对象为 sha256 十六进制字符串）
                guard self.verifySignature(signature, digestHex: expectedSHA) else {
                    FileLogger.log("[Update] 签名验证失败，拒绝更新")
                    self.showAlert(title: "更新失败", text: "安装包校验未通过，请稍后再试")
                    return
                }

                FileLogger.log("[Update] 校验通过，准备安装 \(version)")
                self.install(data: data, file: file)
            }
        }.resume()
    }

    // MARK: - 安装（换包重启）

    private func install(data: Data, file: String) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("cutePetUpdate-\(UUID().uuidString)")
        let zipURL = workDir.appendingPathComponent(file)

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try data.write(to: zipURL)
        } catch {
            FileLogger.log("[Update] 写入临时文件失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, workDir.path]
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            FileLogger.log("[Update] 解压失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return
        }
        guard unzip.terminationStatus == 0 else {
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return
        }

        let contents = (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            showAlert(title: "更新失败", text: "安装包异常，请稍后重试")
            return
        }

        let dest = Bundle.main.bundlePath
        let script = workDir.appendingPathComponent("swap.sh")
        let scriptBody = """
        #!/bin/sh
        PID="$1"; SRC="$2"; DEST="$3"; WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
        rm -rf "$DEST.old"
        mv "$DEST" "$DEST.old" 2>/dev/null
        if ! mv "$SRC" "$DEST"; then
            mv "$DEST.old" "$DEST" 2>/dev/null
            exit 1
        fi
        xattr -cr "$DEST" 2>/dev/null
        open "$DEST"
        sleep 3
        rm -rf "$DEST.old"
        rm -rf "$WORK"
        """
        do {
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            showAlert(title: "更新失败", text: "准备安装失败，请稍后重试")
            return
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, dest, workDir.path]

        let alert = NSAlert()
        alert.messageText = "更新准备好了"
        alert.informativeText = "点「立即重启」，小猫马上回来～"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            FileLogger.log("[Update] 用户选择稍后更新")
            return
        }

        do {
            try helper.run()
        } catch {
            FileLogger.log("[Update] 启动更新脚本失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装启动失败，请稍后重试")
            return
        }

        FileLogger.log("[Update] 即将退出以完成更新")
        NSApp.terminate(nil)
    }

    // MARK: - 工具

    /// Ed25519 验签（对 sha256 十六进制字符串验签）
    private func verifySignature(_ signatureBase64: String, digestHex: String) -> Bool {
        guard let keyData = Data(base64Encoded: releasePublicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signatureData = Data(base64Encoded: signatureBase64),
              let message = digestHex.data(using: .utf8) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: message)
    }

    /// 版本号比较（v 前缀可省略；数字段按数值比较，非数字段按字典序）
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [String] {
            var s = v.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            return s.split(separator: ".").map(String.init)
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : "0"
            let b = i < l.count ? l[i] : "0"
            if let ai = Int(a), let bi = Int(b) {
                if ai != bi { return ai > bi }
            } else if a != b {
                return a > b
            }
        }
        return false
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
