// PayloadCrypto.swift
// DesktopPetForMacApp — 应用层载荷加密
// 敏感字段（激活码、设备 ID 等）用服务端 RSA 公钥加密后传输，避免明文过网。
// 注意：公钥与后端一一对应，切换后端地址时必须同步更新 serverPublicKeyPKCS1。

import Foundation
import Security

enum PayloadCrypto {

    /// 服务端公钥（PKCS#1 DER 的 base64，与 ServerConfig.baseURL 指向的后端对应）
    /// 获取方式：GET {后端}/api/crypto/pubkey → data.publicKeyPkcs1
    static let serverPublicKeyPKCS1 = "MIIBCgKCAQEAuVCckmM0mI7zp1Lssmgxk9pfrHN7upK/IHF+apmEADSc96d4J4u4XrOVDk0Gx6usER+SaMI14jGJteOspr8Dcb1bJO0684YMN/leS6L6kR/kcxGVfdNuEnq9vuWDYpx2omOuijui9owwZ9Eovlpdgpnv8TN/WPk7IUI0Sh6a1rhe6BdVlWK6MXN2SQo0V1sVRJcpvUQ3dGAkZkQt3wgeTdHWmhuc0lSEplsP5DnZdkL/ZBUYY4CLC/vmXN9Km92pUASU4OxjnmtphVFcO6cg/VhfvhqjYYnM74BKO8vfRjz5wvZEEUa1GDRCzgaI7hgOWClVOJyCei9MujYSKreUIQIDAQAB"

    private static let publicKey: SecKey? = {
        guard let der = Data(base64Encoded: serverPublicKeyPKCS1) else {
            FileLogger.log("[PayloadCrypto] 公钥 base64 解码失败")
            return nil
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            FileLogger.log("[PayloadCrypto] 创建公钥失败: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }
        return key
    }()

    /// 加密明文 JSON，返回请求体（{"encrypted": "..."}）
    /// 加密失败返回 nil（调用方应放弃本次请求，不发明文）
    static func encryptedEnvelope(_ plain: Data) -> Data? {
        guard let key = publicKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, plain as CFData, &error) as Data? else {
            FileLogger.log("[PayloadCrypto] 加密失败: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: ["encrypted": cipher.base64EncodedString()])
    }
}
