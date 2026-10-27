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
	svc    *service.HeartbeatService
	social *service.SocialService // 可为 nil：无则心跳不附带宠物号/消息
}

// NewHeartbeatController 创建心跳控制器；social 传 nil 时退化为纯心跳上报
func NewHeartbeatController(svc *service.HeartbeatService, social *service.SocialService) *HeartbeatController {
	return &HeartbeatController{svc: svc, social: social}
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

	data := map[string]any{
		"serverTime": time.Now().Format(time.RFC3339),
		"lastSeenAt": device.LastSeenAt.Format(time.RFC3339),
	}
	// 好友/消息：带 deviceId 的心跳顺带注册宠物号并拉取待展示消息（取后即清）
	if c.social != nil && heartbeat.DeviceID != "" {
		data["petNo"] = c.social.EnsureRegistered(heartbeat.DeviceID, heartbeat.Hostname, heartbeat.PetName)
		if msgs := c.social.TakePendingMessages(heartbeat.DeviceID); len(msgs) > 0 {
			data["messages"] = msgs
		}
	}

	writeJSON(w, http.StatusOK, Response{
		Code: 0,
		Msg:  "ok",
		Data: data,
	})
}

// writeJSON 统一 JSON 响应输出
func writeJSON(w http.ResponseWriter, status int, resp Response) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(resp)
}
