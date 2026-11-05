// src/main/weather-service.js
// DesktopPetElectron — 天气查询（对标 mac 版 Services/WeatherService.swift）
// 走自建 PetServer 转发（/api/weather），上游和风 Key 只在服务端，客户端不接触；
// 城市名先经 OpenStreetMap Nominatim 地理编码拿坐标（与 mac 版 fetchWeatherForecast(forCity:) 一致）。
'use strict';

const config = require('../core/config-store');
const info = require('../core/app-info');

const TIMEOUT_MS = 8000; // 单请求超时（与 mac 版 timeout: 8 一致）

function serverURL(pathname) {
  const base = (config.get('serverBaseURL') || '').replace(/\/+$/, '');
  return `${base}${pathname}`;
}

/** 通用 GET + JSON 解析（失败返回 null） */
async function getJSON(url, headers = {}) {
  try {
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!res.ok) return null;
    return await res.json();
  } catch (e) {
    console.warn(`[weather] 请求失败 ${url}: ${e.message}`);
    return null;
  }
}

/** 天气描述 → emoji 映射（与 mac 版 weatherEmoji 一致） */
function weatherEmoji(text) {
  const t = String(text || '');
  if (t.includes('晴')) return '☀️';
  if (t.includes('多云')) return '⛅';
  if (t.includes('阴')) return '☁️';
  if (t.includes('雨')) return '🌧️';
  if (t.includes('雪')) return '❄️';
  if (t.includes('雷')) return '⛈️';
  if (t.includes('雾') || t.includes('霾')) return '🌫️';
  return '🌤️';
}

/**
 * 创建天气服务。
 * @param {object} [deps]
 * @param {(url: string, headers?: object) => Promise<any>} [deps.getJSON] 注入请求器（单测桩）
 */
function createWeatherService(deps = {}) {
  const httpGet = deps.getJSON || getJSON;

  // IP 定位缓存（国内友好：api.ip.sb，与 mac 版 fetchLocation 同源）
  let cachedLocation = null;

  async function fetchLocation() {
    if (cachedLocation) return cachedLocation;
    const json = await httpGet('https://api.ip.sb/geoip');
    if (!json || !json.city || typeof json.latitude !== 'number' || typeof json.longitude !== 'number') return null;
    cachedLocation = { city: json.city, lat: json.latitude, lon: json.longitude };
    return cachedLocation;
  }

  /** 城市名 → 坐标 + 短名（Nominatim 要带 UA，与服务端条款一致） */
  async function geocodeCity(cityName) {
    const encoded = encodeURIComponent(cityName);
    const json = await httpGet(
      `https://nominatim.openstreetmap.org/search?q=${encoded}&format=json&limit=1`,
      { 'User-Agent': 'DesktopPetElectron/1.0' },
    );
    const first = Array.isArray(json) ? json[0] : null;
    if (!first || !first.lat || !first.lon) return null;
    const shortName = String(first.display_name || cityName).split(',')[0].trim() || cityName;
    return { city: shortName, lat: Number(first.lat), lon: Number(first.lon) };
  }

  /** PetServer 响应 → 前端结构（补 emoji 图标；失败返回 null） */
  function toForecast(data, fallbackCity) {
    if (!data || typeof data !== 'object') return null;
    return {
      city: data.city || fallbackCity || '当前位置',
      nowTemp: data.nowTemp || '?',
      nowText: data.nowText || '未知',
      todayMax: data.todayMax || '?',
      todayMin: data.todayMin || '?',
      hourly: (data.hourly || []).map((h) => ({
        time: h.time || '',
        temp: h.temp || '?',
        text: h.text || '',
        icon: weatherEmoji(h.text),
      })),
      daily: (data.daily || []).map((d) => ({
        dayName: d.dayName || '',
        textDay: d.textDay || '未知',
        tempMax: d.tempMax || '?',
        tempMin: d.tempMin || '?',
        icon: weatherEmoji(d.textDay),
      })),
    };
  }

  /** 按坐标查后端（服务端代持 Key、按 deviceId 限流） */
  async function fetchByCoords({ city, lat, lon }) {
    const params = new URLSearchParams({
      lat: lat.toFixed(4),
      lon: lon.toFixed(4),
      city: city || '',
      deviceId: info.resolveDeviceId(),
    });
    const json = await httpGet(`${serverURL('/api/weather')}?${params}`);
    if (!json || json.code !== 0 || !json.data) {
      console.warn(`[weather] 后端响应异常: ${json ? json.msg : 'null'}`);
      return null;
    }
    return toForecast(json.data, city);
  }

  return {
    /** 本地天气：IP 定位 → 坐标查后端 */
    async fetchLocal() {
      const loc = await fetchLocation();
      if (!loc) return null;
      return fetchByCoords(loc);
    },

    /** 按城市名查询：地理编码 → 坐标查后端 */
    async fetchByCity(cityName) {
      const loc = await geocodeCity(cityName);
      if (!loc) return null;
      return fetchByCoords(loc);
    },
  };
}

module.exports = {
  createWeatherService,
  getJSON,
  weatherEmoji,
  serverURL,
};
