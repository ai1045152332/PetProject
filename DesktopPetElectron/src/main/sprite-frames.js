// src/main/sprite-frames.js
// 内置精灵帧清单：按目录枚举每个状态有几帧，对标 Swift 侧 SpriteSheet.loadFramesFromDirectory。
// 关键：帧数一律由文件系统决定，代码里不写死。素材与 mac 原生版共用 SharedAssets/Sprites 后，
// idel / pet 已从 8 帧迭代到 24 帧，写死会只播前 8 帧、循环在 1/3 处卡断。
'use strict';

const fs = require('fs');
const path = require('path');

const FRAME_RE = /^frame_\d+\.png$/i;

/** 一个状态目录里的帧数（文件名升序播放，与 Swift 一致）；目录读不到返回 0 */
function countFrames(dir, reader) {
  let names;
  try {
    names = reader.readdirSync(dir);
  } catch {
    return 0;
  }
  return names.filter((n) => FRAME_RE.test(n)).length;
}

/**
 * 扫描 Sprites 根目录，得到 { focus: 8, idel: 24, ... }。
 * 根目录缺失/无权限返回空对象，由调用方兜底，绝不抛错拖崩主进程。
 * @param {string} root Sprites 目录（可以是软链，fs 会自动解析）
 * @param {typeof fs} [reader] 可注入的 fs（单测用）
 * @returns {Record<string, number>}
 */
function readFrameCounts(root, reader = fs) {
  const counts = {};
  let entries;
  try {
    entries = reader.readdirSync(root, { withFileTypes: true });
  } catch {
    return counts;
  }
  for (const ent of entries) {
    if (!ent.isDirectory()) continue;
    const n = countFrames(path.join(root, ent.name), reader);
    if (n > 0) counts[ent.name] = n;
  }
  return counts;
}

module.exports = { readFrameCounts, countFrames };
