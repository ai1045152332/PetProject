package controller

import (
	"net/http"
	"time"

	"petserver/internal/service"
)

// DevicesController 在线宠物列表接口控制器
type DevicesController struct {
	svc *service.HeartbeatService
}

// NewDevicesController 创建在线列表控制器
func NewDevicesController(svc *service.HeartbeatService) *DevicesController {
	return &DevicesController{svc: svc}
}

// List 处理 GET /api/devices：返回所有设备及其在线状态
func (c *DevicesController) List(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	devices := c.svc.ListOnlineDevices()

	online := 0
	for _, d := range devices {
		if d.Online {
			online++
		}
	}

	writeJSON(w, http.StatusOK, Response{
		Code: 0,
		Msg:  "ok",
		Data: map[string]any{
			"serverTime": time.Now().Format(time.RFC3339),
			"total":      len(devices),
			"online":     online,
			"devices":    devices,
		},
	})
}
