// src/main/crypto-envelope.js
// DesktopPetElectron — 应用层载荷加密（移植 mac 版 Services/PayloadCrypto.swift）
// 敏感字段（激活码、设备 ID 等）用服务端 RSA 公钥加密后传输，避免明文过网。
// 混合加密：AES-256-GCM 加密数据 + RSA-OAEP(SHA-256) 包裹 AES 密钥，
// 与服务端 internal/crypto/payload.go 的 HybridEnvelope 契约一致：
//   encryptedKey = base64(RSA-OAEP(aesKey32))，data = base64(nonce(12) + ciphertext + tag(16))
// 注意：公钥与后端一一对应，切换后端地址时必须同步更新 SERVER_PUBLIC_KEY_PKCS1。
'use strict';

const crypto = require('crypto');

// 服务端公钥（PKCS#1 DER 的 base64，与 config-store 默认 serverBaseURL 指向的后端对应）
// 获取方式：GET {后端}/api/crypto/pubkey → data.publicKeyPkcs1（与 mac 版同一把）
const SERVER_PUBLIC_KEY_PKCS1 =
  'MIIBCgKCAQEA3slpi18syIxHbqgBajFDsmXVx0HOeCpxNxGY5OM1Ph4/rP41mZVcSXC1KzKIfVR9RWDKqEwJTd4ihBguHq/6f81IJFlzq7aBHKrMypCireDQ+Hk57mUNxW+FGHKCsHlaXF1Qzi4ni8giFZrizdbOyQfBkPhFyrZUJ0PYaGETnkH7m3C6qaMfuHm3S/In50DxO3D5xnDXCYITzHScCmEt/DCaZ8sn7SjI2ScznhwOKR4WwQXYHoPIvaJUW2Q82aeop7/lxLNN6JAgg0cJCTfsoFrYo6S2dqzsnPTb40wJe1LddyCF1zjxV+P5a+I6fVa3jLeQQNvT0m4e1IqpZm0YOQIDAQAB';

/** PKCS#1 公钥 base64 → Node 公钥对象（失败返回 null，调用方走 localError 分支） */
function loadPublicKey(keyBase64) {
  try {
    return crypto.createPublicKey({
      key: Buffer.from(keyBase64, 'base64'),
      format: 'der',
      type: 'pkcs1',
    });
  } catch (e) {
    console.warn('[crypto-envelope] 公钥加载失败:', e.message);
    return null;
  }
}

/**
 * 加密明文 JSON，返回请求体字符串（混合信封）。
 * 加密失败返回 null —— 调用方必须放弃本次请求，绝不回退发明文。
 * @param {Buffer|string} plain 明文 JSON
 * @param {string} [keyBase64] 可注入公钥（单测用），默认内置服务端公钥
 */
function encryptedEnvelope(plain, keyBase64 = SERVER_PUBLIC_KEY_PKCS1) {
  const key = loadPublicKey(keyBase64);
  if (!key) return null;
  try {
    // 1) 随机 AES-256 密钥 + GCM 加密（combined = nonce(12) + ciphertext + tag(16)）
    const aesKey = crypto.randomBytes(32);
    const nonce = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', aesKey, nonce);
    const data = Buffer.concat([
      nonce,
      cipher.update(Buffer.from(plain)),
      cipher.final(),
      cipher.getAuthTag(),
    ]).toString('base64');

    // 2) RSA-OAEP(SHA-256) 包裹 AES 密钥
    const encryptedKey = crypto
      .publicEncrypt(
        { key, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
        aesKey,
      )
      .toString('base64');

    return JSON.stringify({ encryptedKey, data });
  } catch (e) {
    console.warn('[crypto-envelope] 加密失败:', e.message);
    return null;
  }
}

module.exports = { encryptedEnvelope, loadPublicKey, SERVER_PUBLIC_KEY_PKCS1 };
