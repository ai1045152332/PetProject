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
	push   *service.PushService   // 可为 nil：无则心跳不附带运营推送指令
}

// NewHeartbeatController 创建心跳控制器；social 传 nil 时退化为纯心跳上报
func NewHeartbeatController(svc *service.HeartbeatService, social *service.SocialService) *HeartbeatController {
	return &HeartbeatController{svc: svc, social: social}
}

// SetPush 注入推送服务（在 deps 装配时调用，避免构造函数参数继续膨胀）
func (c *HeartbeatController) SetPush(svc *service.PushService) {
	c.push = svc
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
	// 好友/消息：带 deviceId 的心跳顺带注册宠物号、下发待展示消息与待处理好友申请
	// 消息先“探看不取走”（只记下发时间），等客户端看完关卡调 /api/social/read 确认后才真清
	if c.social != nil && heartbeat.DeviceID != "" {
		data["petNo"] = c.social.EnsureRegistered(heartbeat.DeviceID, heartbeat.Hostname, heartbeat.PetName)
		if msgs := c.social.PeekPendingMessages(heartbeat.DeviceID); len(msgs) > 0 {
			data["messages"] = msgs
			c.social.DeliverMessages(heartbeat.DeviceID, msgs) // 登记下发，等接收端确认已读后才从收件箱清除
		}
		if reqs := c.social.PendingRequests(heartbeat.DeviceID); len(reqs) > 0 {
			data["requests"] = reqs
		}
	}
	// 运营推送（更新 / 文字 / 视频）：一次性下发，客户端执行后不再重投
	if c.push != nil && heartbeat.DeviceID != "" {
		if cmds := c.push.PendingFor(heartbeat.DeviceID); len(cmds) > 0 {
			data["commands"] = cmds
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
