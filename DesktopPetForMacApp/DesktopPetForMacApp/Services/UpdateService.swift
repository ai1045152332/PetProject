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

    /// 自动检查间隔：6 小时
    private let checkInterval: TimeInterval = 6 * 3600

    private var timer: Timer?
    private var checking = false
    private var downloading = false

    private init() {}

    /// 启动自动检查（启动 30 秒后首次检查，之后每 6 小时一次）
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

    func checkForUpdate(userInitiated: Bool) {
        guard !checking, !downloading else { return }
        checking = true

        guard let url = URL(string: ServerConfig.baseURL + "/api/app/latest") else {
            checking = false
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.checking = false
                self.handleCheckResult(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleCheckResult(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        if let error {
            FileLogger.log("[Update] 检查更新失败: \(error.localizedDescription)")
            if userInitiated { showAlert(title: "检查更新失败", text: "无法连接更新服务，请检查网络后重试") }
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["data"] as? [String: Any],
              let remoteVersion = info["version"] as? String else {
            if userInitiated { showAlert(title: "暂无可用更新", text: "当前已是最新版本 \(AppVersion.current)") }
            return
        }

        guard Self.isNewer(remoteVersion, than: AppVersion.current) else {
            FileLogger.log("[Update] 已是最新版本 \(AppVersion.current)")
            if userInitiated { showAlert(title: "已是最新版本", text: "当前版本 \(AppVersion.current)") }
            return
        }

        promptAndDownload(version: remoteVersion, notes: (info["notes"] as? String) ?? "", info: info)
    }

    // MARK: - 提示与下载

    private func promptAndDownload(version: String, notes: String, info: [String: Any]) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        alert.informativeText = notes.isEmpty ? "当前版本 \(AppVersion.current)，是否立即更新？" : notes
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
            showAlert(title: "更新失败", text: "更新信息不完整")
            return
        }

        downloading = true
        FileLogger.log("[Update] 开始下载 \(file)")

        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.downloading = false }

                guard let tempURL, error == nil else {
                    self.showAlert(title: "下载失败", text: error?.localizedDescription ?? "未知错误")
                    return
                }
                guard let data = try? Data(contentsOf: tempURL) else {
                    self.showAlert(title: "更新失败", text: "读取安装包失败")
                    return
                }

                // 1) 校验 sha256
                let actualSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actualSHA.lowercased() == expectedSHA.lowercased() else {
                    FileLogger.log("[Update] 摘要不匹配，拒绝更新")
                    self.showAlert(title: "更新包校验失败", text: "安装包摘要不匹配，已中止更新")
                    return
                }

                // 2) Ed25519 验签（签名对象为 sha256 十六进制字符串）
                guard self.verifySignature(signature, digestHex: expectedSHA) else {
                    FileLogger.log("[Update] 签名验证失败，拒绝更新")
                    self.showAlert(title: "更新包验签失败", text: "无法验证安装包来源，已中止更新")
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
            showAlert(title: "更新失败", text: "写入临时文件失败：\(error.localizedDescription)")
            return
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, workDir.path]
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            showAlert(title: "更新失败", text: "解压失败：\(error.localizedDescription)")
            return
        }
        guard unzip.terminationStatus == 0 else {
            showAlert(title: "更新失败", text: "解压安装包失败")
            return
        }

        let contents = (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            showAlert(title: "更新失败", text: "安装包内未找到 App")
            return
        }

        let dest = Bundle.main.bundlePath
        let script = workDir.appendingPathComponent("swap.sh")
        let scriptBody = """
        #!/bin/sh
        PID="$1"; SRC="$2"; DEST="$3"
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
        """
        do {
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            showAlert(title: "更新失败", text: "准备安装脚本失败")
            return
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, dest]

        let alert = NSAlert()
        alert.messageText = "更新已下载完成"
        alert.informativeText = "点击「重启并更新」后小猫会退出，替换文件后自动重新打开。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重启并更新")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            FileLogger.log("[Update] 用户选择稍后更新")
            return
        }

        do {
            try helper.run()
        } catch {
            showAlert(title: "更新失败", text: "启动更新脚本失败：\(error.localizedDescription)")
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
