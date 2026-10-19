package controller

import (
	"encoding/json"
	"net/http"

	"petserver/internal/service"
)

// FileController 服务器文件管理接口（查看/预览/删除），需登录会话或管理密码
type FileController struct {
	authSvc *service.AuthService
	fileSvc *service.FileService
}

// NewFileController 创建文件管理控制器
func NewFileController(authSvc *service.AuthService, fileSvc *service.FileService) *FileController {
	return &FileController{authSvc: authSvc, fileSvc: fileSvc}
}

// authorized 校验管理身份：网页会话令牌（X-Session-Token）或管理密码（X-Admin-Token）
func (c *FileController) authorized(w http.ResponseWriter, r *http.Request) bool {
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

// List 处理 GET /api/admin/files/list?path=相对目录（空表示根目录）
func (c *FileController) List(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	rel := r.URL.Query().Get("path")
	entries, err := c.fileSvc.List(rel)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
		"path":  rel,
		"root":  c.fileSvc.Root(),
		"files": entries,
	}})
}

// Preview 处理 GET /api/admin/files/preview?path=相对文件路径
func (c *FileController) Preview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	rel := r.URL.Query().Get("path")
	if rel == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: path"})
		return
	}

	preview, err := c.fileSvc.Preview(rel)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: preview})
}

// FileDeleteRequest 删除请求
type FileDeleteRequest struct {
	Path string `json:"path"` // 相对根目录的文件/目录路径
}

// Delete 处理 POST /api/admin/files/delete
func (c *FileController) Delete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req FileDeleteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.Path == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: path"})
		return
	}

	if err := c.fileSvc.Delete(req.Path); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}
