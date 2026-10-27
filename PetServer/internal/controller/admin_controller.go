package controller

import (
	"encoding/json"
	"net/http"

	"petserver/internal/model"
	"petserver/internal/service"
)

// AdminController 管理接口控制器（激活码/设备备注等），需登录会话或管理密码
type AdminController struct {
	accessSvc  *service.AccessService
	authSvc    *service.AuthService
	noteSvc    *service.DeviceNoteService
	systemSvc  *service.SystemService
	hbSvc      *service.HeartbeatService
	metricsSvc *service.MetricsService
	socialSvc  *service.SocialService // 可 nil：用于后台查看宠物对话
}

// NewAdminController 创建管理控制器
func NewAdminController(accessSvc *service.AccessService, authSvc *service.AuthService, noteSvc *service.DeviceNoteService, systemSvc *service.SystemService, hbSvc *service.HeartbeatService, metricsSvc *service.MetricsService, socialSvc *service.SocialService) *AdminController {
	return &AdminController{accessSvc: accessSvc, authSvc: authSvc, noteSvc: noteSvc, systemSvc: systemSvc, hbSvc: hbSvc, metricsSvc: metricsSvc, socialSvc: socialSvc}
}

// authorized 校验管理身份：
//  1. 网页登录后的会话令牌（X-Session-Token）
//  2. 脚本/curl 直接带管理密码（X-Admin-Token）
func (c *AdminController) authorized(w http.ResponseWriter, r *http.Request) bool {
	if !c.authSvc.Enabled() {
		writeJSON(w, http.StatusForbidden, Response{Code: 403, Msg: "admin api disabled (PETSERVER_ADMIN_TOKEN not set)"})
		return false
	}
	if c.authSvc.Valid(r.Header.Get("X-Session-Token")) {
		return true
	}
	if c.authSvc.CheckPassword(r.Header.Get("X-Admin-Token")) {
		return true
	}
	writeJSON(w, http.StatusUnauthorized, Response{Code: 401, Msg: "unauthorized"})
	return false
}

// GenerateCodesRequest 生成激活码请求
type GenerateCodesRequest struct {
	Count      int    `json:"count"`      // 生成数量（1~100）
	MaxDevices int    `json:"maxDevices"` // 每码最多绑定设备数（1~10，默认 3）
	ValidDays  int    `json:"validDays"`  // 有效期天数（0 = 永久，上限 3650）
	ImageQuota int    `json:"imageQuota"` // 每码 AI 生图总次数（默认 0 = 未开通，可后台随时改）
	Note       string `json:"note"`       // 备注（购买渠道/买家等）
}

// GenerateCodes 处理 POST /api/admin/codes/generate
func (c *AdminController) GenerateCodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req GenerateCodesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Count < 1 || req.Count > 100 {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "count must be 1~100"})
		return
	}
	if req.MaxDevices == 0 {
		req.MaxDevices = 3
	}
	if req.MaxDevices < 1 || req.MaxDevices > 10 {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "maxDevices must be 1~10"})
		return
	}
	if req.ValidDays < 0 || req.ValidDays > 3650 {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "validDays must be 0~3650 (0 = permanent)"})
		return
	}
	if req.ImageQuota < 0 || req.ImageQuota > 100000 {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "imageQuota must be 0~100000 (0 = 未开通)"})
		return
	}

	codes, err := c.accessSvc.Generate(req.Count, req.MaxDevices, req.ValidDays, req.ImageQuota, req.Note)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "generate failed: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"codes": codes}})
}

// ListCodes 处理 GET /api/admin/codes
func (c *AdminController) ListCodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	codes, err := c.accessSvc.List()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "load failed: " + err.Error()})
		return
	}
	if codes == nil {
		codes = []model.ActivationCode{}
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"codes": codes}})
}

// UnbindRequest 解绑请求
type UnbindRequest struct {
	Code     string `json:"code"`     // 激活码
	DeviceID string `json:"deviceId"` // 设备 ID，留空表示解绑全部设备
}

// UnbindCodes 处理 POST /api/admin/codes/unbind
func (c *AdminController) UnbindCodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req UnbindRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Code == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: code"})
		return
	}

	found, err := c.accessSvc.Unbind(req.Code, req.DeviceID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "unbind failed: " + err.Error()})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, Response{Code: 404, Msg: "code not found"})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}

// DeleteRequest 删除激活码请求
type DeleteRequest struct {
	Code string `json:"code"`
}

// DeleteCodes 处理 POST /api/admin/codes/delete
func (c *AdminController) DeleteCodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req DeleteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Code == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: code"})
		return
	}

	found, err := c.accessSvc.Delete(req.Code)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "delete failed: " + err.Error()})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, Response{Code: 404, Msg: "code not found"})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}

// SetCodeQuotaRequest 设置激活码 AI 生图总次数请求
type SetCodeQuotaRequest struct {
	Code       string `json:"code"`       // 激活码
	ImageQuota int    `json:"imageQuota"` // 新的总次数上限（绝对值，0~100000）
}

// SetCodeQuota 处理 POST /api/admin/codes/quota：设置（覆盖）某码的 AI 生图总次数
func (c *AdminController) SetCodeQuota(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req SetCodeQuotaRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Code == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: code"})
		return
	}
	if req.ImageQuota < 0 || req.ImageQuota > 100000 {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "imageQuota must be 0~100000"})
		return
	}

	found, err := c.accessSvc.SetImageQuota(req.Code, req.ImageQuota)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "set quota failed: " + err.Error()})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, Response{Code: 404, Msg: "code not found"})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}

// DeviceNoteRequest 设置设备备注请求
type DeviceNoteRequest struct {
	Hostname string `json:"hostname"`
	Note     string `json:"note"`
}

// SetDeviceNote 处理 POST /api/admin/devices/note
func (c *AdminController) SetDeviceNote(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req DeviceNoteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Hostname == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: hostname"})
		return
	}

	if err := c.noteSvc.Set(req.Hostname, req.Note); err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "save note failed: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}

// DeviceDeleteRequest 删除设备记录请求
type DeviceDeleteRequest struct {
	Hostname string `json:"hostname"`
}

// DeleteDevice 处理 POST /api/admin/devices/delete：从设备列表与快照中删除，同时清掉备注
// 设备仍在运行时下次心跳会重新登记，用于清理长期离线/换机的残留记录
func (c *AdminController) DeleteDevice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req DeviceDeleteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Hostname == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: hostname"})
		return
	}

	if !c.hbSvc.Remove(req.Hostname) {
		writeJSON(w, http.StatusNotFound, Response{Code: 404, Msg: "device not found"})
		return
	}
	// 备注一并清理（失败不影响删除结果，仅记日志语义由 noteSvc 内部保证）
	_ = c.noteSvc.Set(req.Hostname, "")

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}

// SystemStatus 处理 GET /api/admin/system/status（CPU/内存/网络流量监控）
func (c *AdminController) SystemStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	status, err := c.systemSvc.Snapshot()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "collect failed: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: status})
}

// ApiMetrics 处理 GET /api/admin/metrics：接口调用统计（次数/失败数/耗时）
func (c *AdminController) ApiMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: c.metricsSvc.Snapshot()})
}

// ResetApiMetrics 处理 POST /api/admin/metrics/reset：清零全部接口计数，重新开始统计
func (c *AdminController) ResetApiMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	c.metricsSvc.Reset()
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}

// SocialConversations 处理 GET /api/admin/social/conversations：返回好友间的对话留痕（旧 → 新）
func (c *AdminController) SocialConversations(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}
	if c.socialSvc == nil {
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"conversations": []model.PetConversationRecord{}}})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"conversations": c.socialSvc.Conversations()}})
}

// ClearSocialConversations 处理 POST /api/admin/social/conversations/clear：清空全部对话留痕
func (c *AdminController) ClearSocialConversations(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}
	if c.socialSvc == nil {
		writeJSON(w, http.StatusOK, Response{Code: 1, Msg: "social service unavailable"})
		return
	}

	if err := c.socialSvc.ClearConversations(); err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "clear failed: " + err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}
