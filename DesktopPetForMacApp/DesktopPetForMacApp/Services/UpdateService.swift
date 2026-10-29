// UpdateService.swift
// DesktopPetForMacApp — 客户端自动更新
// 流程：检查版本 → 提示 → 下载安装包 → 校验 sha256 + Ed25519 验签 → 解包换包重启
// 安装包优先用 dmg（与官网手动下载同源），老服务端没有 dmg 字段时退回 zip
// 残留治理：安装前扫掉历史更新包，装完由换包脚本连工作目录一起删除
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
            // 开机顺手清掉历史版本遗留的更新包，即使这次没有新版本也能把残留收掉
            self?.cleanupStaleUpdateArtifacts()
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
            if userInitiated { showAlert(title: "已经是最新版本", text: "有新版本时宠物会第一时间告诉你") }
            return
        }

        guard Self.isNewer(remoteVersion, than: AppVersion.current) else {
            FileLogger.log("[Update] 已是最新版本 \(AppVersion.current)")
            if userInitiated { showAlert(title: "已经是最新版本", text: "有新版本时宠物会第一时间告诉你") }
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
        guard let package = Self.selectPackage(from: info),
              let url = URL(string: ServerConfig.baseURL + "/download/\(package.file)") else {
            showAlert(title: "更新失败", text: "更新信息不完整，请稍后再试")
            return
        }
        let file = package.file
        let expectedSHA = package.sha256
        let signature = package.signature

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

    /// 选包：dmg 优先，三件套字段缺失时回落 zip，保证对老 manifest 也可用
    private static func selectPackage(from info: [String: Any]) -> (file: String, sha256: String, signature: String)? {
        if let dmg = info["dmgFile"] as? String, !dmg.isEmpty,
           let sha = info["dmgSHA256"] as? String, !sha.isEmpty,
           let sig = info["dmgSignature"] as? String, !sig.isEmpty {
            return (dmg, sha, sig)
        }
        if let zip = info["file"] as? String, !zip.isEmpty,
           let sha = info["sha256"] as? String, !sha.isEmpty,
           let sig = info["signature"] as? String, !sig.isEmpty {
            return (zip, sha, sig)
        }
        return nil
    }

    // MARK: - 安装（换包重启）

    private func install(data: Data, file: String) {
        let fm = FileManager.default
        // 开工前先清掉上一版遗留的更新包，否则每次更新都会多一份旧包堆在临时目录
        cleanupStaleUpdateArtifacts()

        let workDir = fm.temporaryDirectory.appendingPathComponent("cutePetUpdate-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            FileLogger.log("[Update] 创建临时目录失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return
        }

        // 两种格式都收敛成 workDir 内的一个 .app（与安装目标同盘），换包脚本只跑本地 mv
        guard let newApp = unpack(data: data, file: file, workDir: workDir) else {
            try? fm.removeItem(at: workDir)
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
        alert.informativeText = "点「立即重启」，宠物马上回来～"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            FileLogger.log("[Update] 用户选择稍后更新")
            // 不重启就不留残留：连已下载的更新包一起删掉，下次检查会重新下
            try? fm.removeItem(at: workDir)
            return
        }

        do {
            try helper.run()
        } catch {
            FileLogger.log("[Update] 启动更新脚本失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装启动失败，请稍后重试")
            // 换包脚本没跑起来，不会有 rm 收尾，这里自己把更新包清掉
            try? fm.removeItem(at: workDir)
            return
        }

        FileLogger.log("[Update] 即将退出以完成更新")
        NSApp.terminate(nil)
    }

    // MARK: - 解包（zip / dmg 两条通路）

    /// 按扩展名分发到对应解包通路，失败已在内部弹提示
    private func unpack(data: Data, file: String, workDir: URL) -> URL? {
        if file.lowercased().hasSuffix(".dmg") {
            return unpackDMG(data: data, file: file, workDir: workDir)
        }
        return unpackZIP(data: data, file: file, workDir: workDir)
    }

    /// zip 通路：ditto 直接解到 workDir，产物与安装目标同盘，可近乎瞬时 mv 换包
    private func unpackZIP(data: Data, file: String, workDir: URL) -> URL? {
        let fm = FileManager.default
        let packageURL = workDir.appendingPathComponent(file)
        do {
            try data.write(to: packageURL)
        } catch {
            FileLogger.log("[Update] 写入临时文件失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return nil
        }
        guard run("/usr/bin/ditto", ["-x", "-k", packageURL.path, workDir.path]) else {
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return nil
        }
        let contents = (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            showAlert(title: "更新失败", text: "安装包异常，请稍后重试")
            return nil
        }
        return app
    }

    /// dmg 通路：挂载是只读卷，不能直接 mv 换包，先 ditto 拷成 workDir 内的本地副本再交给换包脚本
    private func unpackDMG(data: Data, file: String, workDir: URL) -> URL? {
        let fm = FileManager.default
        let packageURL = workDir.appendingPathComponent(file)
        do {
            try data.write(to: packageURL)
        } catch {
            FileLogger.log("[Update] 写入临时文件失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return nil
        }

        // 挂载点固定指到 workDir 下：卷名带空格，且 /Volumes 下同名卷会被追加序号，写死路径会偶发找不到源
        let mountDir = workDir.appendingPathComponent("mnt")
        do {
            try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
        } catch {
            FileLogger.log("[Update] 创建挂载目录失败: \(error.localizedDescription)")
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return nil
        }

        // -nobrowse 避免挂载卷自己弹一个 Finder 窗口；摘要已经在本机校验过，-noverify 跳过 dmg 内置校验再省一轮
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-mountpoint", mountDir.path, packageURL.path]) else {
            showAlert(title: "更新失败", text: "安装包挂载失败，请稍后重试")
            return nil
        }
        // 无论后续成败都必须卸载，否则挂载卷残留会让下一次删除和更新全部踩坑
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mountDir.path]) }

        let contents = (try? fm.contentsOfDirectory(at: mountDir, includingPropertiesForKeys: nil)) ?? []
        guard let mountedApp = contents.first(where: { $0.pathExtension == "app" }) else {
            showAlert(title: "更新失败", text: "安装包异常，请稍后重试")
            return nil
        }

        // ditto 保留权限与符号链接，拷出来的 app 与解压 zip 得到的结果一致
        let stagedApp = workDir.appendingPathComponent(mountedApp.lastPathComponent)
        guard run("/usr/bin/ditto", [mountedApp.path, stagedApp.path]) else {
            showAlert(title: "更新失败", text: "安装过程中出错了，请稍后重试")
            return nil
        }
        return stagedApp
    }

    /// 同步跑一个外部命令（沿用原有主线程 waitUntilExit 的写法），失败只记日志
    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            FileLogger.log("[Update] 命令执行失败 \(launchPath): \(error.localizedDescription)")
            return false
        }
        guard p.terminationStatus == 0 else {
            FileLogger.log("[Update] 命令非 0 退出 \(launchPath): \(p.terminationStatus)")
            return false
        }
        return true
    }

    /// 扫掉临时目录里历史遗留的更新包（旧版本 dmg/zip 与解压产物），避免一次更新堆一份
    private func cleanupStaleUpdateArtifacts() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                     includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("cutePetUpdate-") {
            // 老版本遗留目录里可能有还挂着的只读卷，不先卸载 removeItem 会失败
            _ = run("/usr/bin/hdiutil", ["detach", "-force", item.appendingPathComponent("mnt").path])
            do {
                try fm.removeItem(at: item)
                FileLogger.log("[Update] 已清理历史更新残留: \(item.lastPathComponent)")
            } catch {
                FileLogger.log("[Update] 清理历史更新残留失败: \(error.localizedDescription)")
            }
        }
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
