// Package storage 负责心跳数据的本地持久化
package storage

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"petserver/internal/model"
)

// 心跳日志重写时使用的临时文件命名模式
const tempFilePattern = ".heartbeats-*.tmp"

// HeartbeatStore 以 JSON Lines 格式把心跳追加到本地文件（一行一条）
type HeartbeatStore struct {
	mu   sync.Mutex
	file *os.File
}

// NewHeartbeatStore 打开（不存在则创建）持久化文件
func NewHeartbeatStore(path string) (*HeartbeatStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	return &HeartbeatStore{file: file}, nil
}

// Append 追加一条设备心跳记录
func (s *HeartbeatStore) Append(device model.Device) error {
	line, err := json.Marshal(device)
	if err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = s.file.Write(append(line, '\n'))
	return err
}

// Close 关闭底层文件
func (s *HeartbeatStore) Close() error {
	return s.file.Close()
}

// CleanupBefore 清理 lastSeenAt 早于 cutoff 的心跳日志，返回删除的条数。
// 损坏行（无法解析的 JSON）一并清理；空行直接丢弃。
// 整个过程持有写锁与 Append 互斥，重写采用「同目录临时文件 + rename」原子替换，
// 避免清理途中崩溃导致日志文件损坏。
func (s *HeartbeatStore) CleanupBefore(cutoff time.Time) (removed int, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	path := s.file.Name()
	dir := filepath.Dir(path)

	// 顺手清扫历史遗留的孤儿临时文件（进程被强杀时可能残留）
	sweepStaleTempFiles(dir)

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil // 文件尚不存在，无需清理
		}
		return 0, err
	}

	var kept bytes.Buffer
	for _, line := range bytes.Split(data, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 { // 空行（含文件末尾换行）直接丢弃
			continue
		}
		var d model.Device
		if uerr := json.Unmarshal(line, &d); uerr != nil || d.LastSeenAt.Before(cutoff) {
			removed++
			continue
		}
		kept.Write(line)
		kept.WriteByte('\n')
	}

	tmp, err := os.CreateTemp(dir, ".heartbeats-*.tmp")
	if err != nil {
		return removed, err
	}
	tmpName := tmp.Name()
	// 无论后续成功与否（含 panic 路径），临时文件都不能留在业务目录里；
	// rename 成功后置空 tmpName，defer 不再误删正式文件
	defer func() {
		if tmpName != "" {
			os.Remove(tmpName)
		}
	}()

	if _, werr := tmp.Write(kept.Bytes()); werr != nil {
		tmp.Close()
		return removed, werr
	}
	if cerr := tmp.Chmod(0o644); cerr != nil {
		tmp.Close()
		return removed, cerr
	}
	if cerr := tmp.Close(); cerr != nil {
		return removed, cerr
	}
	if rerr := os.Rename(tmpName, path); rerr != nil {
		return removed, rerr
	}
	tmpName = "" // 已成为正式文件

	// 重新打开追加句柄（旧句柄指向已被替换的 inode）
	newFile, oerr := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if oerr != nil {
		return removed, oerr
	}
	_ = s.file.Close()
	s.file = newFile
	return removed, nil
}

// sweepStaleTempFiles 删除目录内超过 1 分钟未被改动的孤儿临时文件。
// 正常执行中的临时文件生命周期在毫秒级，超过 1 分钟一定是残留垃圾。
func sweepStaleTempFiles(dir string) {
	matches, err := filepath.Glob(filepath.Join(dir, tempFilePattern))
	if err != nil {
		return
	}
	for _, m := range matches {
		if fi, err := os.Stat(m); err == nil && time.Since(fi.ModTime()) > time.Minute {
			if rmErr := os.Remove(m); rmErr == nil {
				log.Printf("[storage] 已清扫残留临时文件: %s", filepath.Base(m))
			}
		}
	}
}
