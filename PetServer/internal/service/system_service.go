// Package service 系统状态服务：采集 CPU / 内存 / 网络流量，供后台监控页展示。
// 仅支持 Linux（读取 /proc），其他平台返回错误。
package service

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
)

const sampleInterval = 250 * time.Millisecond // 单次采样窗口

// SystemService 采集服务器运行状态
type SystemService struct {
	mu       sync.Mutex
	lastStat statSample // 上次 CPU 采样
	hasStat  bool
	lastNet  netCounters // 上次网络采样
	hasNet   bool
}

// NewSystemService 创建系统状态服务
func NewSystemService() *SystemService {
	return &SystemService{}
}

type statSample struct {
	total   uint64 // 所有 jiffy 总数
	idle    uint64 // idle + iowait
	at      time.Time
}

// Snapshot 采集一次系统状态（CPU/内存/网络/负载/运行时长）
func (s *SystemService) Snapshot() (*model.SystemStatus, error) {
	cores, err := os.ReadFile("/sys/devices/system/cpu/present")
	if err != nil {
		return nil, fmt.Errorf("system status only supported on linux: %w", err)
	}
	cores = []byte(strings.TrimSpace(string(cores)))

	cpu, err := s.cpuPercent()
	if err != nil {
		return nil, err
	}
	mem, err := readMemInfo()
	if err != nil {
		return nil, err
	}
	rxTotal, txTotal, rxRate, txRate, err := s.netRates()
	if err != nil {
		return nil, err
	}
	load1, load5, load15, err := readLoadAvg()
	if err != nil {
		return nil, err
	}
	uptime, err := readUptime()
	if err != nil {
		return nil, err
	}
	host, _ := os.Hostname()
	vnstat := s.readVnstatDaily()

	memUsed := mem.total - mem.avail
	memPct := 0.0
	if mem.total > 0 {
		memPct = float64(memUsed) / float64(mem.total) * 100
	}

	return &model.SystemStatus{
		CPUPercent:     cpu,
		Cores:          parseCores(cores),
		Load1:          load1,
		Load5:          load5,
		Load15:         load15,
		MemTotal:       mem.total,
		MemUsed:        memUsed,
		MemUsedPercent: memPct,
		Hostname:       host,
		UptimeSeconds:  int64(uptime.Seconds()),
		Net: model.NetStatus{
			RxBytes: rxTotal,
			TxBytes: txTotal,
			RxRate:  rxRate,
			TxRate:  txRate,
		},
		VnstatDaily: vnstat,
	}, nil
}

// cpuPercent 计算自上次调用以来的 CPU 使用率；首次调用采样一个短窗口。
func (s *SystemService) cpuPercent() (float64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	cur, err := readStat()
	if err != nil {
		return 0, err
	}
	prev := cur
	if s.hasStat && time.Since(s.lastStat.at) < 5*time.Second {
		prev = s.lastStat
	} else {
		time.Sleep(sampleInterval)
		if cur, err = readStat(); err != nil {
			return 0, err
		}
	}
	s.lastStat, s.hasStat = cur, true

	dTotal := float64(cur.total - prev.total)
	dIdle := float64(cur.idle - prev.idle)
	if dTotal <= 0 {
		return 0, nil
	}
	pct := (1 - dIdle/dTotal) * 100
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct, nil
}

// netRates 计算自上次调用以来的收发速率，并返回累计字节数。
func (s *SystemService) netRates() (rxTotal, txTotal, rxRate, txRate uint64, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	cur, err := readNetDev()
	if err != nil {
		return 0, 0, 0, 0, err
	}
	prev := cur
	if s.hasNet && time.Since(s.lastNet.at) < 5*time.Second {
		prev = s.lastNet
	} else {
		time.Sleep(sampleInterval)
		if cur, err = readNetDev(); err != nil {
			return 0, 0, 0, 0, err
		}
	}
	s.lastNet, s.hasNet = cur, true

	seconds := cur.at.Sub(prev.at).Seconds()
	if seconds <= 0 {
		return cur.rx, cur.tx, 0, 0, nil
	}
	return cur.rx, cur.tx,
		uint64(float64(cur.rx-prev.rx) / seconds),
		uint64(float64(cur.tx-prev.tx) / seconds),
		nil
}

// readStat 读取 /proc/stat 的 CPU 汇总行
func readStat() (statSample, error) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return statSample{}, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)[1:]
		var total, idle uint64
		for i, f := range fields {
			v, _ := strconv.ParseUint(f, 10, 64)
			total += v
			if i == 3 || i == 4 { // idle + iowait
				idle += v
			}
		}
		return statSample{total: total, idle: idle, at: time.Now()}, nil
	}
	return statSample{}, fmt.Errorf("cpu line not found in /proc/stat")
}

type memInfo struct {
	total, avail uint64
}

// readMemInfo 读取 /proc/meminfo（单位 kB）
func readMemInfo() (memInfo, error) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return memInfo{}, err
	}
	var info memInfo
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		v, _ := strconv.ParseUint(fields[1], 10, 64)
		switch fields[0] {
		case "MemTotal:":
			info.total = v * 1024
		case "MemAvailable:":
			info.avail = v * 1024
		}
	}
	if info.total == 0 {
		return memInfo{}, fmt.Errorf("MemTotal not found in /proc/meminfo")
	}
	return info, nil
}

type netCounters struct {
	rx, tx uint64
	at     time.Time
}

// readNetDev 汇总除 lo 外所有网卡的收发字节数（含采样时间戳）
func readNetDev() (netCounters, error) {
	data, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		return netCounters{}, err
	}
	var total netCounters
	total.at = time.Now()
	for _, line := range strings.Split(string(data), "\n")[2:] {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		name := strings.TrimSpace(parts[0])
		if name == "lo" {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) < 9 {
			continue
		}
		rx, _ := strconv.ParseUint(fields[0], 10, 64)
		tx, _ := strconv.ParseUint(fields[8], 10, 64)
		total.rx += rx
		total.tx += tx
	}
	if total.rx == 0 && total.tx == 0 {
		return netCounters{}, fmt.Errorf("no traffic counters found in /proc/net/dev")
	}
	return total, nil
}

// readVnstatDaily 读取 vnstat 按天流量统计（实测 vnstat 2.9 JSON 输出单位为字节）。
// vnstat 未安装或执行失败时返回空列表，不影响主接口。
func (s *SystemService) readVnstatDaily() []model.VnstatDay {
	out, err := exec.Command("vnstat", "--json", "d", "30").Output()
	if err != nil {
		return []model.VnstatDay{}
	}
	var payload struct {
		Interfaces []struct {
			Name    string `json:"name"`
			Traffic struct {
				Day []struct {
					Date struct {
						Year  int `json:"year"`
						Month int `json:"month"`
						Day   int `json:"day"`
					} `json:"date"`
					Rx  float64 `json:"rx"`  // 字节
					Tx  float64 `json:"tx"`  // 字节
					RxK float64 `json:"rxk"` // 额外精度（字节部分）
					TxK float64 `json:"txk"` // 额外精度（字节部分）
				} `json:"day"`
			} `json:"traffic"`
		} `json:"interfaces"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return []model.VnstatDay{}
	}

	days := []model.VnstatDay{}
	for _, itf := range payload.Interfaces {
		if itf.Name == "lo" {
			continue
		}
		for _, d := range itf.Traffic.Day {
			days = append(days, model.VnstatDay{
				Date: fmt.Sprintf("%04d-%02d-%02d", d.Date.Year, d.Date.Month, d.Date.Day),
				Rx:   uint64(d.Rx + d.RxK),
				Tx:   uint64(d.Tx + d.TxK),
			})
		}
	}
	return days
}

// readLoadAvg 读取 1/5/15 分钟负载
func readLoadAvg() (l1, l5, l15 float64, err error) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, 0, err
	}
	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return 0, 0, 0, fmt.Errorf("unexpected /proc/loadavg format")
	}
	l1, _ = strconv.ParseFloat(fields[0], 64)
	l5, _ = strconv.ParseFloat(fields[1], 64)
	l15, _ = strconv.ParseFloat(fields[2], 64)
	return l1, l5, l15, nil
}

// readUptime 读取系统运行时长
func readUptime() (time.Duration, error) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(data))
	if len(fields) < 1 {
		return 0, fmt.Errorf("unexpected /proc/uptime format")
	}
	secs, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, err
	}
	return time.Duration(secs * float64(time.Second)), nil
}

// parseCores 从 "0-1" / "0" 这类 CPU 列表解析核心数
func parseCores(present []byte) int {
	s := string(present)
	if dash := strings.IndexByte(s, '-'); dash >= 0 {
		lo, _ := strconv.Atoi(s[:dash])
		hi, _ := strconv.Atoi(s[dash+1:])
		if hi >= lo {
			return hi - lo + 1
		}
	}
	if n, err := strconv.Atoi(s); err == nil {
		return n + 1
	}
	return 1
}
