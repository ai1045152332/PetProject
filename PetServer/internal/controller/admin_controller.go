package controller

import (
	"encoding/json"
	"net/http"

	"petserver/internal/model"
	"petserver/internal/service"
)

// AdminController 管理接口控制器（激活码生成/查询），需 X-Admin-Token 鉴权
type AdminController struct {
	accessSvc *service.AccessService
	authSvc   *service.AuthService
}

// NewAdminController 创建管理控制器
func NewAdminController(accessSvc *service.AccessService, authSvc *service.AuthService) *AdminController {
	return &AdminController{accessSvc: accessSvc, authSvc: authSvc}
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

	codes, err := c.accessSvc.Generate(req.Count, req.MaxDevices, req.ValidDays, req.Note)
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
