// Package controller：服务端主动推送（更新 / 文字 / 视频）
// 运营在后台提交一条指令，客户端下次心跳（最长 1 分钟）就会收到并执行。
package controller

import (
	"encoding/json"
	"net/http"
	"time"

	"petserver/internal/model"
	"petserver/internal/service"
)

// PushController 推送指令管理接口（需管理身份）
type PushController struct {
	authSvc *service.AuthService
	svc     *service.PushService
}

// NewPushController 创建推送控制器
func NewPushController(authSvc *service.AuthService, svc *service.PushService) *PushController {
	return &PushController{authSvc: authSvc, svc: svc}
}

func (c *PushController) authorized(w http.ResponseWriter, r *http.Request) bool {
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

// pushRequest 新建推送请求
type pushRequest struct {
	DeviceID    string `json:"deviceId"`    // 空 = 广播
	Kind        string `json:"kind"`        // update / text / video
	Title       string `json:"title"`       // 卡片标题（可选）
	Text        string `json:"text"`        // 文字内容（kind=text 必填）
	URL         string `json:"url"`         // 视频地址（kind=video 必填）
	DurationMs  int64  `json:"durationMs"`  // 文字卡自动关闭毫秒（0 = 手动关）
	ExpiresMins int    `json:"expiresMins"` // 有效期分钟（0 = 默认 24 小时）
}

// Create 处理 POST /api/admin/push
func (c *PushController) Create(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}

	var req pushRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	cmd := model.PushCommand{
		DeviceID:   req.DeviceID,
		Kind:       req.Kind,
		Title:      req.Title,
		Text:       req.Text,
		URL:        req.URL,
		DurationMs: req.DurationMs,
	}
	if req.ExpiresMins > 0 {
		cmd.ExpiresAt = time.Now().Add(time.Duration(req.ExpiresMins) * time.Minute)
	}

	saved, err := c.svc.Enqueue(cmd)
	if err != nil {
		writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: saved})
}

// List 处理 GET /api/admin/push
func (c *PushController) List(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
		"commands": c.svc.List(),
	}})
}

// Delete 处理 POST /api/admin/push/delete {id}
func (c *PushController) Delete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.authorized(w, r) {
		return
	}
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}
	if req.ID == "" {
		writeJSON(w, http.StatusOK, Response{Code: 1, Msg: "缺少 id"})
		return
	}
	if err := c.svc.Delete(req.ID); err != nil {
		writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
}
