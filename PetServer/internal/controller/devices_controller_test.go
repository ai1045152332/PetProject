package controller

import (
	"testing"

	"petserver/internal/model"
)

// TestSortDeviceViews 在线宠物列表固定排序：在线优先，其次宠物号升序，无号的排最后
func TestSortDeviceViews(t *testing.T) {
	devices := []model.DeviceView{
		{Heartbeat: model.Heartbeat{Hostname: "off-small-no"}, PetNo: 5, Online: false},
		{Heartbeat: model.Heartbeat{Hostname: "on-big-no"}, PetNo: 88, Online: true},
		{Heartbeat: model.Heartbeat{Hostname: "on-no-note"}, PetNo: 0, Online: true},
		{Heartbeat: model.Heartbeat{Hostname: "on-small-no"}, PetNo: 7, Online: true},
		{Heartbeat: model.Heartbeat{Hostname: "off-big-no"}, PetNo: 3, Online: false},
		{Heartbeat: model.Heartbeat{Hostname: "a-same"}, PetNo: 7, Online: true},
	}

	sortDeviceViews(devices)

	want := []string{"a-same", "on-small-no", "on-big-no", "on-no-note", "off-big-no", "off-small-no"}
	for i, name := range want {
		if devices[i].Hostname != name {
			t.Fatalf("排序结果不符：第 %d 位期望 %s，实际 %s（完整：%v）",
				i, name, devices[i].Hostname, hostnames(devices))
		}
	}
}

func hostnames(devices []model.DeviceView) []string {
	out := make([]string, 0, len(devices))
	for _, d := range devices {
		out = append(out, d.Hostname)
	}
	return out
}
