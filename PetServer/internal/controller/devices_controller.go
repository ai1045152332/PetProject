package controller

import (
	"math"
	"net/http"
	"sort"
	"time"

	"petserver/internal/model"
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

	sortDeviceViews(devices)

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

// sortDeviceViews 固定排序规则：在线优先，其次按宠物号升序（未分配宠物号的排最后），
// 其余情况按主机名兜底，保证每次刷新列表顺序稳定不跳动
func sortDeviceViews(devices []model.DeviceView) {
	sort.SliceStable(devices, func(i, j int) bool {
		if devices[i].Online != devices[j].Online {
			return devices[i].Online
		}
		if noI, noJ := petNoRank(devices[i].PetNo), petNoRank(devices[j].PetNo); noI != noJ {
			return noI < noJ
		}
		return devices[i].Hostname < devices[j].Hostname
	})
}

// petNoRank 宠物号排序权重：0 表示尚未分配，视为最大，排到有号的后面
func petNoRank(no int64) int64 {
	if no == 0 {
		return math.MaxInt64
	}
	return no
}
