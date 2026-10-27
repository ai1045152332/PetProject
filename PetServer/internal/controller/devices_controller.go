package controller

import (
	"net/http"
	"time"

	"petserver/internal/service"
)

// DevicesController 在线宠物列表接口控制器
type DevicesController struct {
	svc     *service.HeartbeatService
	noteSvc *service.DeviceNoteService
	social  *service.SocialService // 可 nil：用于在列表展示宠物号
}

// NewDevicesController 创建在线列表控制器
func NewDevicesController(svc *service.HeartbeatService, noteSvc *service.DeviceNoteService, social *service.SocialService) *DevicesController {
	return &DevicesController{svc: svc, noteSvc: noteSvc, social: social}
}

// List 处理 GET /api/devices：返回所有设备及其在线状态
func (c *DevicesController) List(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	devices := c.svc.ListOnlineDevices()

	// 填充管理端维护的设备备注
	notes := c.noteSvc.All()
	for i := range devices {
		if note, ok := notes[devices[i].Hostname]; ok {
			devices[i].Note = note
		}
		// 宠物号由好友体系按 deviceId 分配；未注册时为 0，前端显示占位
		if c.social != nil {
			devices[i].PetNo = c.social.PetNoFor(devices[i].DeviceID)
		}
	}

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
