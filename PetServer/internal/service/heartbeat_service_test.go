package service

import (
	"path/filepath"
	"testing"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

func newHeartbeatServiceForTest(t *testing.T) *HeartbeatService {
	t.Helper()
	dir := t.TempDir()

	store, err := storage.NewHeartbeatStore(filepath.Join(dir, "heartbeats.jsonl"))
	if err != nil {
		t.Fatalf("创建心跳存储失败: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	snapshot, err := storage.NewDeviceSnapshotStore(filepath.Join(dir, "devices.json"))
	if err != nil {
		t.Fatalf("创建设备快照存储失败: %v", err)
	}
	return NewHeartbeatService(store, snapshot)
}

func hb(hostname, deviceID, petName string) model.Heartbeat {
	return model.Heartbeat{
		Version:  "electron0.0.1",
		Hostname: hostname,
		OS:       "macOS Version 15.6.1 (Build 24G90)",
		Machine:  "arm64",
		PetName:  petName,
		PetState: "focus",
		DeviceID: deviceID,
	}
}

// 同一台机器两个客户端（mac 原生版 / Electron 版）主机名大小写不同，但 deviceId 相同：
// 必须归并成一条记录，否则设备列表会重复展示同一个宠物号
func TestRecordMergesSameDeviceIDDifferentHostname(t *testing.T) {
	svc := newHeartbeatServiceForTest(t)
	const deviceID = "68B62601-BB91-55CA-99ED-4DDBD7B93B92"

	svc.Record(hb("mbp-jcxnyjc9dv-1911.local", deviceID, "kimi"))
	svc.Record(hb("MBP-JCXNYJC9DV-1911.local", deviceID, "毛豆"))

	devices := svc.ListDevices()
	if len(devices) != 1 {
		t.Fatalf("同一 deviceId 应只保留一条记录，实际 %d 条", len(devices))
	}
	// 后到的心跳覆盖展示字段（列表展示最新一次上报）
	if devices[0].Hostname != "MBP-JCXNYJC9DV-1911.local" || devices[0].PetName != "毛豆" {
		t.Fatalf("应展示最新一次心跳，实际 hostname=%s petName=%s", devices[0].Hostname, devices[0].PetName)
	}
}

// 主机名相同但 deviceId 不同（换机重装、克隆机）是两台设备，必须各占一条
func TestRecordKeepsDistinctDeviceIDs(t *testing.T) {
	svc := newHeartbeatServiceForTest(t)

	svc.Record(hb("same.local", "AAAA-1111", "毛豆"))
	svc.Record(hb("same.local", "BBBB-2222", "灰灰"))

	if got := len(svc.ListDevices()); got != 2 {
		t.Fatalf("不同 deviceId 应各占一条记录，实际 %d 条", got)
	}
}

// 旧客户端不带 deviceId：退回主机名做键，并做大小写归一
func TestRecordFallsBackToHostnameWithoutDeviceID(t *testing.T) {
	svc := newHeartbeatServiceForTest(t)

	svc.Record(hb("Old-Mac.local", "", "毛豆"))
	svc.Record(hb("old-mac.local", "", "毛豆"))

	if got := len(svc.ListDevices()); got != 1 {
		t.Fatalf("无 deviceId 时应按主机名归并（大小写不敏感），实际 %d 条", got)
	}
}

// 删除接口原来只认主机名，现在 deviceId / 主机名（任意大小写）都能删
func TestRemoveByDeviceIDOrHostname(t *testing.T) {
	svc := newHeartbeatServiceForTest(t)
	const deviceID = "68B62601-BB91-55CA-99ED-4DDBD7B93B92"
	svc.Record(hb("mbp-a.local", deviceID, "毛豆"))

	if !svc.Remove(deviceID) {
		t.Fatal("按 deviceId 应能删除")
	}
	if got := len(svc.ListDevices()); got != 0 {
		t.Fatalf("删除后应为 0 条，实际 %d", got)
	}

	svc.Record(hb("mbp-a.local", deviceID, "毛豆"))
	if !svc.Remove("MBP-A.LOCAL") {
		t.Fatal("按主机名（大小写不敏感）应能删除")
	}
	if svc.Remove("not-exist") {
		t.Fatal("不存在的设备应返回 false")
	}
}

// 旧快照以主机名为 key：启动加载时应按 deviceId 归并，避免重启后重复又冒出来
func TestRestoreSnapshotMergesLegacyHostnameKeys(t *testing.T) {
	dir := t.TempDir()
	snapshotPath := filepath.Join(dir, "devices.json")

	snapshot, err := storage.NewDeviceSnapshotStore(snapshotPath)
	if err != nil {
		t.Fatalf("创建快照存储失败: %v", err)
	}
	const deviceID = "68B62601-BB91-55CA-99ED-4DDBD7B93B92"
	legacy := map[string]model.Device{
		"mbp-jcxnyjc9dv-1911.local": {
			Heartbeat:  hb("mbp-jcxnyjc9dv-1911.local", deviceID, "kimi"),
			LastSeenAt: time.Now().Add(-time.Minute),
		},
		"MBP-JCXNYJC9DV-1911.local": {
			Heartbeat:  hb("MBP-JCXNYJC9DV-1911.local", deviceID, "毛豆"),
			LastSeenAt: time.Now(),
		},
	}
	if err := snapshot.Save(legacy); err != nil {
		t.Fatalf("写入旧格式快照失败: %v", err)
	}

	store, err := storage.NewHeartbeatStore(filepath.Join(dir, "heartbeats.jsonl"))
	if err != nil {
		t.Fatalf("创建心跳存储失败: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	svc := NewHeartbeatService(store, snapshot)
	devices := svc.ListDevices()
	if len(devices) != 1 {
		t.Fatalf("旧快照中同一 deviceId 的两条记录应归并为一条，实际 %d 条", len(devices))
	}
	if devices[0].PetName != "毛豆" {
		t.Fatalf("归并后应保留最后一次心跳（毛豆），实际 %s", devices[0].PetName)
	}
}
