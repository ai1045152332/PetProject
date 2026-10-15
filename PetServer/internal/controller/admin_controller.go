package controller

import (
	"encoding/json"
	"net/http"

	"petserver/internal/model"
	"petserver/internal/service"
)

// AdminController 管理接口控制器（激活码生成/查询），需 X-Admin-Token 鉴权
type AdminController struct {
	accessSvc  *service.AccessService
	adminToken string // 管理令牌（环境变量 PETSERVER_ADMIN_TOKEN 注入，空则管理接口全部禁用）
}

// NewAdminController 创建管理控制器
func NewAdminController(accessSvc *service.AccessService, adminToken string) *AdminController {
	return &AdminController{accessSvc: accessSvc, adminToken: adminToken}
}

// authorized 校验管理令牌
func (c *AdminController) authorized(w http.ResponseWriter, r *http.Request) bool {
	if c.adminToken == "" {
		writeJSON(w, http.StatusForbidden, Response{Code: 403, Msg: "admin api disabled (PETSERVER_ADMIN_TOKEN not set)"})
		return false
	}
	if r.Header.Get("X-Admin-Token") != c.adminToken {
		writeJSON(w, http.StatusUnauthorized, Response{Code: 401, Msg: "invalid admin token"})
		return false
	}
	return true
}

// GenerateCodesRequest 生成激活码请求
type GenerateCodesRequest struct {
	Count      int    `json:"count"`      // 生成数量（1~100）
	MaxDevices int    `json:"maxDevices"` // 每码最多绑定设备数（1~10，默认 3）
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

	codes, err := c.accessSvc.Generate(req.Count, req.MaxDevices, req.Note)
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
