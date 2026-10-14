// Package storage 的单元测试：验证心跳日志按时间清理
package storage

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"petserver/internal/model"
)

func makeDevice(hostname string, seen time.Time) model.Device {
	return model.Device{
		Heartbeat: model.Heartbeat{
			Version:  "v1.0.001.test",
			Hostname: hostname,
			OS:       "macOS 15.6.1",
			Machine:  "arm64",
			PetName:  "测试",
			PetState: "idel",
		},
		LastSeenAt: seen,
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取日志文件失败: %v", err)
	}
	return string(data)
}

// 清理应删除过期行与损坏行，保留新鲜行，且清理后仍可正常追加
func TestCleanupBefore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "heartbeats.jsonl")

	store, err := NewHeartbeatStore(path)
	if err != nil {
		t.Fatalf("初始化存储失败: %v", err)
	}
	defer store.Close()

	now := time.Now()
	stale := makeDevice("stale-host", now.Add(-10*time.Minute))
	fresh := makeDevice("fresh-host", now.Add(-1*time.Minute))

	for _, d := range []model.Device{stale, fresh} {
		if err := store.Append(d); err != nil {
			t.Fatalf("写入心跳失败: %v", err)
		}
	}
	// 模拟历史脏数据：损坏行 + 空行
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("打开文件失败: %v", err)
	}
	if _, err := f.WriteString("not-a-json\n\n"); err != nil {
		t.Fatalf("写入脏数据失败: %v", err)
	}
	f.Close()

	removed, err := store.CleanupBefore(now.Add(-5 * time.Minute))
	if err != nil {
		t.Fatalf("清理失败: %v", err)
	}
	// stale(过期) + not-a-json(损坏) 共 2 条，空行不计入
	if removed != 2 {
		t.Errorf("期望清理 2 条，实际 %d 条", removed)
	}

	content := readFile(t, path)
	if !strings.Contains(content, "fresh-host") {
		t.Errorf("新鲜日志被误删:\n%s", content)
	}
	if strings.Contains(content, "stale-host") || strings.Contains(content, "not-a-json") {
		t.Errorf("过期/损坏日志未被清理:\n%s", content)
	}

	// 清理后（文件被原子替换）追加仍应正常
	again := makeDevice("again-host", now)
	if err := store.Append(again); err != nil {
		t.Fatalf("清理后追加失败: %v", err)
	}
	content = readFile(t, path)
	if !strings.Contains(content, "again-host") {
		t.Errorf("清理后追加的内容丢失:\n%s", content)
	}
}

// 文件不存在时清理应安全返回
func TestCleanupBeforeEmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "heartbeats.jsonl")

	store, err := NewHeartbeatStore(path)
	if err != nil {
		t.Fatalf("初始化存储失败: %v", err)
	}
	defer store.Close()

	removed, err := store.CleanupBefore(time.Now().Add(-5 * time.Minute))
	if err != nil {
		t.Fatalf("空文件清理不应报错: %v", err)
	}
	if removed != 0 {
		t.Errorf("期望清理 0 条，实际 %d 条", removed)
	}
}

// 清理时应顺手清扫历史遗留的孤儿临时文件（进程被强杀的残留场景）
func TestCleanupSweepsOrphanTempFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "heartbeats.jsonl")

	store, err := NewHeartbeatStore(path)
	if err != nil {
		t.Fatalf("初始化存储失败: %v", err)
	}
	defer store.Close()

	// 模拟两个孤儿临时文件：一个超过 1 分钟（应被清扫），一个是刚创建的（不动）
	orphanOld := filepath.Join(dir, ".heartbeats-111.tmp")
	orphanFresh := filepath.Join(dir, ".heartbeats-222.tmp")
	for _, name := range []string{orphanOld, orphanFresh} {
		if err := os.WriteFile(name, []byte("junk"), 0o600); err != nil {
			t.Fatalf("创建孤儿临时文件失败: %v", err)
		}
	}
	old := time.Now().Add(-2 * time.Minute)
	if err := os.Chtimes(orphanOld, old, old); err != nil {
		t.Fatalf("修改时间戳失败: %v", err)
	}

	if err := store.Append(makeDevice("h1", time.Now())); err != nil {
		t.Fatalf("写入心跳失败: %v", err)
	}
	if _, err := store.CleanupBefore(time.Now().Add(-5 * time.Minute)); err != nil {
		t.Fatalf("清理失败: %v", err)
	}

	if _, err := os.Stat(orphanOld); !os.IsNotExist(err) {
		t.Errorf("超过 1 分钟的孤儿临时文件应被清扫")
	}
	if _, err := os.Stat(orphanFresh); err != nil {
		t.Errorf("1 分钟内创建的临时文件不应被误删")
	}
	// 清理任务自身的临时文件也不应残留
	remaining, _ := filepath.Glob(filepath.Join(dir, ".heartbeats-*.tmp"))
	if len(remaining) != 1 { // 仅剩我们手工创建的 orphanFresh
		t.Errorf("期望仅剩 1 个手工创建的文件，实际: %v", remaining)
	}
}

