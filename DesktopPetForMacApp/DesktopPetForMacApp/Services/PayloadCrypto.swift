// PayloadCrypto.swift
// DesktopPetForMacApp — 应用层载荷加密
// 敏感字段（激活码、设备 ID 等）用服务端 RSA 公钥加密后传输，避免明文过网。
// 注意：公钥与后端一一对应，切换后端地址时必须同步更新 serverPublicKeyPKCS1。

import Foundation
import Security

enum PayloadCrypto {

    /// 服务端公钥（PKCS#1 DER 的 base64，与 ServerConfig.baseURL 指向的后端对应）
    /// 获取方式：GET {后端}/api/crypto/pubkey → data.publicKeyPkcs1
    static let serverPublicKeyPKCS1 = "MIIBCgKCAQEA3slpi18syIxHbqgBajFDsmXVx0HOeCpxNxGY5OM1Ph4/rP41mZVcSXC1KzKIfVR9RWDKqEwJTd4ihBguHq/6f81IJFlzq7aBHKrMypCireDQ+Hk57mUNxW+FGHKCsHlaXF1Qzi4ni8giFZrizdbOyQfBkPhFyrZUJ0PYaGETnkH7m3C6qaMfuHm3S/In50DxO3D5xnDXCYITzHScCmEt/DCaZ8sn7SjI2ScznhwOKR4WwQXYHoPIvaJUW2Q82aeop7/lxLNN6JAgg0cJCTfsoFrYo6S2dqzsnPTb40wJe1LddyCF1zjxV+P5a+I6fVa3jLeQQNvT0m4e1IqpZm0YOQIDAQAB"

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
