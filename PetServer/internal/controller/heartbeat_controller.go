// Package controller 承载 HTTP 请求处理（入参解析、响应封装）
package controller

import (
	"encoding/json"
	"net/http"
	"time"

	"petserver/internal/model"
	"petserver/internal/service"
)

// Response 统一响应信封
type Response struct {
	Code int    `json:"code"` // 0 成功，非 0 失败
	Msg  string `json:"msg"`
	Data any    `json:"data,omitempty"`
}

// HeartbeatController 心跳接口控制器
type HeartbeatController struct {
	svc *service.HeartbeatService
}

// NewHeartbeatController 创建心跳控制器
func NewHeartbeatController(svc *service.HeartbeatService) *HeartbeatController {
	return &HeartbeatController{svc: svc}
}

// Report 处理 POST /api/heartbeat
func (c *HeartbeatController) Report(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	var heartbeat model.Heartbeat
	if err := json.NewDecoder(r.Body).Decode(&heartbeat); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}

	if field := heartbeat.Validate(); field != "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: " + field})
		return
	}

	device := c.svc.Record(heartbeat)

	writeJSON(w, http.StatusOK, Response{
		Code: 0,
		Msg:  "ok",
		Data: map[string]any{
			"serverTime": time.Now().Format(time.RFC3339),
			"lastSeenAt": device.LastSeenAt.Format(time.RFC3339),
		},
	})
}

// writeJSON 统一 JSON 响应输出
func writeJSON(w http.ResponseWriter, status int, resp Response) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(resp)
}
