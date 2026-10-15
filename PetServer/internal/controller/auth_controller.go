package controller

import (
	"encoding/json"
	"net/http"

	"petserver/internal/service"
)

// AuthController 管理后台认证接口
type AuthController struct {
	authSvc *service.AuthService
}

// NewAuthController 创建认证控制器
func NewAuthController(authSvc *service.AuthService) *AuthController {
	return &AuthController{authSvc: authSvc}
}

// LoginRequest 登录请求
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// Login 处理 POST /api/admin/login
func (c *AuthController) Login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authSvc.Enabled() {
		writeJSON(w, http.StatusForbidden, Response{Code: 403, Msg: "admin api disabled (PETSERVER_ADMIN_TOKEN not set)"})
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}

	token, expiresAt, ok := c.authSvc.Login(req.Username, req.Password)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, Response{Code: 401, Msg: "账号或密码错误"})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
		"token":     token,
		"expiresAt": expiresAt.Format(http.TimeFormat),
	}})
}

// Logout 处理 POST /api/admin/logout
func (c *AuthController) Logout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	c.authSvc.Logout(r.Header.Get("X-Session-Token"))
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}
