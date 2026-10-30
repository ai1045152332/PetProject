// src/main/update-service.js
// DesktopPetElectron — 客户端自动更新（检查 / 下载 / 校验 / 安装）
// 移植自 mac 版 Services/UpdateService.swift：
//   检查版本 → 提示 → 下载安装包 → sha256 + Ed25519 验签 → 交平台各自的安装通路
// 与服务端契约：GET /api/app/latest 取 manifest，GET /download/<文件名> 取包
// 跨平台字段：win32 读 winVersion/winFile/winSHA256/winSignature，macOS 读 macVersion/macFile/macSHA256/macSignature
//   （不带平台前缀的 version/file 属于 mac 原生 Swift 版，Electron 版绝不能拿来更新自己）
// 安全模型：App 只内置 Ed25519 公钥，私钥离线保存在发布者本机（~/.cute-pet-release）
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Readable, Transform } = require('stream');
const { pipeline } = require('stream/promises');
const { spawn } = require('child_process');
const { app, dialog, shell } = require('electron');
const config = require('./config-store');
const info = require('./app-info');

// 发布签名公钥（Ed25519 raw 32 字节 base64，与 mac 版 UpdateService.releasePublicKeyBase64 同一把）
const RELEASE_PUBLIC_KEY_BASE64 = 'JeaR8M5ddeR67FkgsD+F2f3TNYRuAv5YRrJzTkaDWP0=';
// Ed25519 原始公钥包成 SPKI DER 的固定前缀（Node crypto 只接受 DER/PEM）
const SPKI_ED25519_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const FIRST_CHECK_DELAY_MS = 30 * 1000;          // 启动 30 秒后首次检查（对齐 mac 版）
const CHECK_INTERVAL_MS = 24 * 3600 * 1000;      // 之后每 24 小时一次
const CHECK_TIMEOUT_MS = 10 * 1000;
const DOWNLOAD_TIMEOUT_MS = 10 * 60 * 1000;

/** 平台 → manifest 字段前缀 + 允许的安装包扩展名 */
function platformSpec() {
  if (process.platform === 'win32') {
    return { prefix: 'win', label: 'Windows', extensions: ['.exe', '.msi'] };
  }
  if (process.platform === 'darwin') {
    return { prefix: 'mac', label: 'macOS', extensions: ['.dmg', '.zip'] };
  }
  return null;
}

function serverURL(pathname) {
  const base = (config.get('serverBaseURL') || '').replace(/\/+$/, '');
  return `${base}${pathname}`;
}

function str(value) {
  return typeof value === 'string' ? value.trim() : '';
}

/** 版本号比较（前缀 v / electron 均可省略；数字段按数值比较，非数字段按字典序），与 mac 版 isNewer 同语义 */
function isNewer(remote, local) {
  // 先剥掉 electron / v 前缀再比，保证 electron0.0.2 与 v0.0.2 视为同一版本序列
  const parts = (v) => info.normalizeVersion(v).split('.');
  const r = parts(remote);
  const l = parts(local);
  const len = Math.max(r.length, l.length);
  for (let i = 0; i < len; i += 1) {
    const a = i < r.length ? r[i] : '0';
    const b = i < l.length ? l[i] : '0';
    const ai = Number.parseInt(a, 10);
    const bi = Number.parseInt(b, 10);
    if (!Number.isNaN(ai) && !Number.isNaN(bi)) {
      if (ai !== bi) return ai > bi;
    } else if (a !== b) {
      return a > b;
    }
  }
  return false;
}

/** 从 manifest 里挑出本平台的安装包，缺字段或无匹配扩展名时返回 null */
function selectPackage(payload) {
  const spec = platformSpec();
  if (!spec) return null;

  // 版本号必须独立：只认带平台前缀的字段，绝不回落到无前缀的 version/notes
  // （无前缀的那套属于 mac 原生 Swift 版，回落会导致本机版本被反复误判为旧版）
  const version = str(payload[`${spec.prefix}Version`]);
  const file = str(payload[`${spec.prefix}File`]);
  const sha256 = str(payload[`${spec.prefix}SHA256`]);
  const signature = str(payload[`${spec.prefix}Signature`]);
  if (!version || !file || !sha256 || !signature) return null;
  if (!spec.extensions.includes(path.extname(file).toLowerCase())) return null;

  return {
    version,
    notes: str(payload[`${spec.prefix}Notes`]),
    file,
    sha256,
    signature,
  };
}

/** Ed25519 验签：签名对象是 sha256 的十六进制字符串 */
function verifySignature(signatureBase64, digestHex) {
  try {
    const publicKey = crypto.createPublicKey({
      key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(RELEASE_PUBLIC_KEY_BASE64, 'base64')]),
      format: 'der',
      type: 'spki',
    });
    return crypto.verify(
      null,
      Buffer.from(digestHex, 'utf8'),
      publicKey,
      Buffer.from(signatureBase64, 'base64'),
    );
  } catch (e) {
    console.warn('[update] 验签异常:', e.message);
    return false;
  }
}

class UpdateService {
  /**
   * @param {object} [opts]
   * @param {(status: object) => void} [opts.onStatus] 状态回调（供托盘展示进度）
   */
  constructor({ onStatus } = {}) {
    this.onStatus = onStatus || (() => {});
    this.firstTimer = null;
    this.repeatTimer = null;
    this.checking = false;
    this.downloading = false;
  }

  /** 启动自动检查：30 秒后首次（顺带清理历史更新残留），之后每 24 小时一次 */
  start() {
    if (this.firstTimer || this.repeatTimer) return;
    this.firstTimer = setTimeout(() => {
      this.firstTimer = null;
      this.cleanupStaleArtifacts();
      this.checkForUpdate({ userInitiated: false });
    }, FIRST_CHECK_DELAY_MS);
    this.repeatTimer = setInterval(() => {
      this.checkForUpdate({ userInitiated: false });
    }, CHECK_INTERVAL_MS);
  }

  stop() {
    if (this.firstTimer) {
      clearTimeout(this.firstTimer);
      this.firstTimer = null;
    }
    if (this.repeatTimer) {
      clearInterval(this.repeatTimer);
      this.repeatTimer = null;
    }
  }

  /**
   * 检查更新
   * @param {object} [opts]
   * @param {boolean} [opts.userInitiated] 用户主动触发：无更新/失败时也弹提示
   */
  async checkForUpdate({ userInitiated = false } = {}) {
    if (this.checking || this.downloading) {
      if (userInitiated) this.alert('正在检查更新', '请稍等一下，当前还有任务在进行中。');
      return;
    }
    this.checking = true;
    this.onStatus({ phase: 'checking' });

    try {
      const res = await fetch(serverURL('/api/app/latest'), {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(CHECK_TIMEOUT_MS),
      });
      if (!res.ok) throw new Error(`状态码 ${res.status}`);
      const json = await res.json();
      const payload = (json && json.data) || {};
      config.set('lastUpdateCheckAt', Date.now());

      const pkg = selectPackage(payload);
      if (!pkg) {
        const spec = platformSpec();
        console.log('[update] 服务端暂无当前平台的安装包');
        if (userInitiated) {
          this.alert(
            '暂无可用更新',
            spec
              ? `服务端还没有发布 ${spec.label} 版安装包，发布后宠物会第一时间告诉你。`
              : '当前系统暂不支持自动更新，请访问官网手动下载。',
          );
        }
        return;
      }

      if (!isNewer(pkg.version, info.currentVersion())) {
        console.log(`[update] 已是最新版本 ${info.currentVersion()}`);
        if (userInitiated) this.alert('已经是最新版本', `当前 ${info.currentVersion()}，有新版本时宠物会第一时间告诉你。`);
        return;
      }

      this.onStatus({ phase: 'available', version: pkg.version });
      const accepted = await this.promptUpdate(pkg);
      if (!accepted) {
        console.log(`[update] 用户选择稍后更新到 ${pkg.version}`);
        return;
      }
      await this.downloadAndInstall(pkg);
    } catch (e) {
      console.warn('[update] 检查更新失败:', e.message);
      if (userInitiated) this.alert('检查更新失败', '网络好像不太稳定，稍后再试试。');
    } finally {
      this.checking = false;
      this.onStatus({ phase: 'idle' });
    }
  }

  // ── 提示与下载 ────────────────────────────────────────────

  async promptUpdate(pkg) {
    const { response } = await dialog.showMessageBox({
      type: 'info',
      title: `有新版本啦 ${pkg.version}`,
      message: `发现新版本 ${pkg.version}（当前 ${info.currentVersion()}）`,
      detail: pkg.notes || '要不要现在就更新？',
      buttons: ['立即更新', '稍后'],
      defaultId: 0,
      cancelId: 1,
      noLink: true,
    });
    return response === 0;
  }

  /** 下载 → 校验 sha256 → Ed25519 验签，返回安装包本地路径 */
  async downloadAndInstall(pkg) {
    const dir = path.join(app.getPath('userData'), 'updates');
    const dest = path.join(dir, pkg.file);

    this.downloading = true;
    this.onStatus({ phase: 'downloading', version: pkg.version, percent: 0 });
    try {
      fs.mkdirSync(dir, { recursive: true });
      console.log(`[update] 开始下载 ${pkg.file}`);
      const digest = await this.download(serverURL(`/download/${encodeURIComponent(pkg.file)}`), dest, (percent) => {
        this.onStatus({ phase: 'downloading', version: pkg.version, percent });
      });

      if (digest.toLowerCase() !== pkg.sha256.toLowerCase()) {
        console.warn('[update] sha256 不匹配，拒绝更新');
        this.alert('更新失败', '安装包可能不完整，请稍后再试。');
        this.removeQuietly(dest);
        return;
      }
      if (!verifySignature(pkg.signature, pkg.sha256)) {
        console.warn('[update] 签名验证失败，拒绝更新');
        this.alert('更新失败', '安装包校验未通过，请稍后再试。');
        this.removeQuietly(dest);
        return;
      }

      console.log(`[update] 校验通过，准备安装 ${pkg.version}`);
      this.onStatus({ phase: 'ready', version: pkg.version });
      await this.install(dest, pkg.version);
    } catch (e) {
      console.warn('[update] 下载失败:', e.message);
      this.alert('更新下载失败', '网络好像不太稳定，稍后再试试。');
      this.removeQuietly(dest);
    } finally {
      this.downloading = false;
      this.onStatus({ phase: 'idle' });
    }
  }

  /** 流式下载，边写盘边算 sha256，返回 hex 摘要 */
  async download(url, dest, onProgress) {
    const res = await fetch(url, { signal: AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS) });
    if (!res.ok || !res.body) throw new Error(`状态码 ${res.status}`);

    const total = Number(res.headers.get('content-length') || 0);
    const hash = crypto.createHash('sha256');
    let received = 0;
    let lastReported = -1;

    const meter = new Transform({
      transform(chunk, _enc, cb) {
        hash.update(chunk);
        received += chunk.length;
        if (total > 0) {
          const percent = Math.floor((received / total) * 100);
          if (percent !== lastReported) {
            lastReported = percent;
            onProgress(percent);
          }
        }
        cb(null, chunk);
      },
    });

    await pipeline(Readable.fromWeb(res.body), meter, fs.createWriteStream(dest));
    return hash.digest('hex');
  }

  // ── 安装 ─────────────────────────────────────────────────

  async install(filePath, version) {
    const ext = path.extname(filePath).toLowerCase();

    if (process.platform === 'win32' && (ext === '.exe' || ext === '.msi')) {
      // 便携版（portable 目标）是单文件 exe，运行在临时解包目录里，无法自我替换；
      // electron-builder 会注入 PORTABLE_EXECUTABLE_FILE 等环境变量作为识别依据
      if (process.env.PORTABLE_EXECUTABLE_FILE) {
        shell.showItemInFolder(filePath);
        this.alert(
          '便携版需手动替换',
          `当前是免安装的便携版，自动更新无法替换正在运行的程序。新版本 ${version} 已下载到本机，请退出宠物后用新文件替换旧的 exe；换成安装版（setup）后可自动更新。`,
        );
        return;
      }

      const { response } = await dialog.showMessageBox({
        type: 'info',
        title: '更新准备好了',
        message: `点「立即重启」安装 ${version}，宠物马上回来。`,
        buttons: ['立即重启', '稍后'],
        defaultId: 0,
        cancelId: 1,
        noLink: true,
      });
      if (response !== 0) {
        console.log('[update] 用户选择稍后安装');
        this.removeQuietly(filePath);
        return;
      }
      // NSIS 安装包静默安装（/S），装完自动拉起新版本；msi 交给系统安装器
      const args = ext === '.msi' ? ['/i', filePath, '/qb'] : ['/S'];
      const command = ext === '.msi' ? 'msiexec' : filePath;
      const child = ext === '.msi'
        ? spawn(command, args, { detached: true, stdio: 'ignore', windowsHide: true })
        : spawn(command, args, { detached: true, stdio: 'ignore' });
      child.unref();

      // 给安装器留出接管时间再退出，避免它删不动正在运行的 exe
      setTimeout(() => {
        this.onStatus({ phase: 'installing', version });
        app.quit();
      }, 1200);
      return;
    }

    if (process.platform === 'darwin' && ext === '.dmg') {
      // macOS 上不做静默替换（需要 hdiutil 挂载 + 换包脚本），打开 dmg 让用户拖进「应用程序」
      const err = await shell.openPath(filePath);
      if (err) {
        this.alert('更新失败', `安装包打不开：${err}`);
        return;
      }
      this.alert('更新已下载', '把宠物拖到「应用程序」文件夹即可完成更新，之后手动打开新的宠物。');
      return;
    }

    // 其余情况（如 zip 包）不擅自解压替换，直接把文件亮给用户
    shell.showItemInFolder(filePath);
    this.alert('更新已下载', '安装包已保存到本机，请按压缩包内说明手动安装。');
  }

  // ── 工具 ─────────────────────────────────────────────────

  /** 清掉历史遗留的更新包（每次自动检查前跑一次，避免旧包一直堆着） */
  cleanupStaleArtifacts() {
    const dir = path.join(app.getPath('userData'), 'updates');
    let items = [];
    try {
      items = fs.readdirSync(dir);
    } catch (e) {
      return;
    }
    for (const name of items) {
      const full = path.join(dir, name);
      this.removeQuietly(full);
    }
    if (items.length > 0) console.log(`[update] 已清理历史更新残留 ${items.length} 个`);
  }

  removeQuietly(target) {
    try {
      fs.rmSync(target, { recursive: true, force: true });
    } catch (e) {
      console.warn('[update] 删除失败:', e.message);
    }
  }

  alert(title, text) {
    dialog.showMessageBox({
      type: 'info',
      title,
      message: title,
      detail: text,
      buttons: ['好'],
      noLink: true,
    }).catch(() => {});
  }
}

module.exports = { UpdateService, isNewer, verifySignature, selectPackage };
