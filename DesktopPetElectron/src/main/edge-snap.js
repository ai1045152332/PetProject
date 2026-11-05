// src/main/edge-snap.js
// 贴边躲藏的纯计算部分（对标 mac 原生版 PetViewModel.snapToEdgeForHiding / revealFromEdge）。
// 抽成无 Electron 依赖的函数，方便 node 直跑单测（index.js 只负责拿真实窗口 bounds 调用它）。
// 规则与 mac 版一致：躲藏素材是「从一侧探头」，只支持左/右侧边；距边小于 trigger 即吸附，
// 窗口整边对齐显示器工作区边缘，素材的裁切边正好落在屏幕边上（渲染层负责把画面贴到该边）。
'use strict';

const TRIGGER = 60;  // 距屏幕侧边小于该距离即触发吸附（mac 版同为 60pt）
const REVEAL_INSET = 4; // 现身时至少收进屏内这么多像素，避免醒来仍半个身子在屏外

/**
 * 拖动结束时判断是否贴边，贴边则算出吸附后的窗口位置。
 * @param {object} input
 * @param {{x:number,y:number,width:number,height:number}} input.bounds 当前窗口矩形（DIP）
 * @param {{x:number,y:number,width:number,height:number}} input.area 所在显示器工作区
 * @param {boolean} [input.requiresNearEdge] false = 右键「躲起来」，不看距离直接吸到最近一侧
 * @param {number} [input.trigger] 触发距离阈值
 * @returns {{facing:'left'|'right', bounds:{x:number,y:number,width:number,height:number}, gap:number} | null}
 *          null = 没贴边，不吸附
 */
function snapToEdgeForHiding({ bounds, area, requiresNearEdge = true, trigger = TRIGGER }) {
  if (!bounds || !area) return null;
  const size = { width: bounds.width, height: bounds.height };
  const dLeft = bounds.x - area.x;
  const dRight = area.x + area.width - (bounds.x + bounds.width);
  const candidates = [{ facing: 'left', dist: dLeft }, { facing: 'right', dist: dRight }];
  const nearest = candidates.reduce((a, b) => (b.dist < a.dist ? b : a));
  if (requiresNearEdge && nearest.dist >= trigger) return null;

  // 纵向始终夹在工作区内（贴顶/贴底不会跑出可视范围）
  const y = Math.min(Math.max(bounds.y, area.y), Math.max(area.y, area.y + area.height - size.height));
  const x = nearest.facing === 'left' ? area.x : area.x + area.width - size.width;
  return {
    facing: nearest.facing,
    gap: Math.round(Math.max(0, nearest.dist)),
    bounds: { x: Math.round(x), y: Math.round(y), width: size.width, height: size.height },
  };
}

/**
 * 从躲藏中现身：把窗口完整收回屏内（保留当前尺寸）。
 * @param {object} input
 * @param {{x:number,y:number,width:number,height:number}} input.bounds 当前窗口矩形
 * @param {{x:number,y:number,width:number,height:number}} input.area 所在显示器工作区
 * @param {number} [input.inset] 收进屏内的留白
 * @returns {{x:number,y:number,width:number,height:number}}
 */
function revealFromEdge({ bounds, area, inset = REVEAL_INSET }) {
  if (!bounds || !area) return bounds;
  const maxX = Math.max(area.x, area.x + area.width - bounds.width - inset);
  const maxY = Math.max(area.y, area.y + area.height - bounds.height - inset);
  return {
    x: Math.round(Math.min(Math.max(bounds.x, area.x + inset), maxX)),
    y: Math.round(Math.min(Math.max(bounds.y, area.y + inset), maxY)),
    width: bounds.width,
    height: bounds.height,
  };
}

module.exports = { snapToEdgeForHiding, revealFromEdge, TRIGGER, REVEAL_INSET };
