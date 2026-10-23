package controller

import (
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"

	"petserver/internal/service"
)

// FileController 服务器文件管理接口（查看/预览/下载/删除），需登录会话或管理密码
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

// Download 处理 GET /api/admin/files/download?path=相对文件路径
// 安装包、词库等文件体积可能很大，不截断直接流式返回；交给 http.ServeFile 以支持分段/断点续传。
// 会话令牌仍走请求头，因此后台页用 fetch 拿到二进制后再触发保存。
func (c *FileController) Download(w http.ResponseWriter, r *http.Request) {
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

	target, err := c.fileSvc.PrepareDownload(rel)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: err.Error()})
		return
	}

	// 文件名可能含中文，按 RFC 5987 用 filename* 传递，同时给出 ASCII 兜底
	w.Header().Set("Content-Disposition", attachmentDisposition(target.Name))
	log.Printf("[files] 下载文件: %s（%d 字节）", rel, target.Size)
	http.ServeFile(w, r, target.FullPath)
}

// attachmentDisposition 拼出强制下载响应头，兼容不支持 filename* 的老浏览器
// 真实文件名走 RFC 5987 的 filename*；老浏览器用的 filename 只保留 ASCII，
// 非 ASCII 直接写进报头会变成乱码，所以先洗掉，洗空了就用带扩展名的兜底名。
func attachmentDisposition(name string) string {
	fallback := strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e || r == '"' || r == '\\' {
			return '_'
		}
		return r
	}, name)
	if strings.Trim(strings.ReplaceAll(fallback, "_", ""), " .-") == "" {
		fallback = "download" + filepath.Ext(name)
	}
	// QueryEscape 把空格编成 +，RFC 5987 需要 %20
	encoded := strings.ReplaceAll(url.QueryEscape(name), "+", "%20")
	return `attachment; filename="` + fallback + `"; filename*=UTF-8''` + encoded
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
