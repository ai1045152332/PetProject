package service

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
)

// weatherTimeout 单次上游请求超时
const weatherTimeout = 6 * time.Second

// WeatherService 天气服务：服务端持 Key 调上游，客户端不接触 Key
// （天气接口按量付费，Key 只存在服务器环境变量里）
type WeatherService struct {
	host   string
	key    string
	client *http.Client

	mu       sync.Mutex
	requests map[string][]time.Time // key(设备/IP) → 最近请求时间
}

// NewWeatherService 创建天气服务；key 为空时接口返回 503（功能未配置）
func NewWeatherService(host, key string) *WeatherService {
	if host == "" {
		host = "kv359hcbtd.re.qweatherapi.com"
	}
	return &WeatherService{
		host:     host,
		key:      key,
		client:   &http.Client{Timeout: weatherTimeout},
		requests: make(map[string][]time.Time),
	}
}

// Enabled 是否已配置天气 Key
func (s *WeatherService) Enabled() bool { return s.key != "" }

// Allow 简单限流：同一标识在 window 内最多 limit 次
func (s *WeatherService) Allow(ident string, limit int, window time.Duration) bool {
	now := time.Now()
	cutoff := now.Add(-window)

	s.mu.Lock()
	defer s.mu.Unlock()

	kept := make([]time.Time, 0, len(s.requests[ident]))
	for _, t := range s.requests[ident] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= limit {
		s.requests[ident] = kept
		return false
	}
	s.requests[ident] = append(kept, now)
	return true
}

// Fetch 查询天气（按坐标）
func (s *WeatherService) Fetch(city string, lat, lon float64) (*model.WeatherResult, error) {
	if !s.Enabled() {
		return nil, fmt.Errorf("天气服务未配置")
	}

	loc := fmt.Sprintf("%.4f,%.4f", lon, lat)

	// 1. 实时天气
	var now struct {
		Code string `json:"code"`
		Now  struct {
			Temp string `json:"temp"`
			Text string `json:"text"`
		} `json:"now"`
	}
	if err := s.getJSON(fmt.Sprintf("/v7/weather/now?location=%s&key=%s", loc, s.key), &now); err != nil {
		return nil, err
	}
	if now.Code != "200" {
		return nil, fmt.Errorf("上游返回 code=%s", now.Code)
	}

	// 2. 逐小时（取前 6 条）
	var hourlyResp struct {
		Code   string `json:"code"`
		Hourly []struct {
			FxTime string `json:"fxTime"`
			Temp   string `json:"temp"`
			Text   string `json:"text"`
		} `json:"hourly"`
	}
	hourly := make([]model.WeatherHourly, 0, 6)
	if err := s.getJSON(fmt.Sprintf("/v7/weather/24h?location=%s&key=%s", loc, s.key), &hourlyResp); err == nil && hourlyResp.Code == "200" {
		for i, h := range hourlyResp.Hourly {
			if i >= 6 {
				break
			}
			hourly = append(hourly, model.WeatherHourly{
				Time: formatHour(h.FxTime),
				Temp: h.Temp,
				Text: h.Text,
			})
		}
	}

	// 3. 三日预报
	var dailyResp struct {
		Code  string `json:"code"`
		Daily []struct {
			TextDay string `json:"textDay"`
			TempMax string `json:"tempMax"`
			TempMin string `json:"tempMin"`
		} `json:"daily"`
	}
	if err := s.getJSON(fmt.Sprintf("/v7/weather/3d?location=%s&key=%s", loc, s.key), &dailyResp); err != nil {
		return nil, err
	}
	if dailyResp.Code != "200" || len(dailyResp.Daily) == 0 {
		return nil, fmt.Errorf("上游三日预报异常 code=%s", dailyResp.Code)
	}

	dayNames := []string{"今天", "明天", "后天"}
	daily := make([]model.WeatherDaily, 0, len(dailyResp.Daily))
	for i, d := range dailyResp.Daily {
		name := fmt.Sprintf("第%d天", i+1)
		if i < len(dayNames) {
			name = dayNames[i]
		}
		daily = append(daily, model.WeatherDaily{
			DayName: name,
			TextDay: d.TextDay,
			TempMax: d.TempMax,
			TempMin: d.TempMin,
		})
	}

	if city == "" {
		city = "当前位置"
	}

	result := &model.WeatherResult{
		City:     city,
		NowTemp:  now.Now.Temp,
		NowText:  now.Now.Text,
		TodayMax: dailyResp.Daily[0].TempMax,
		TodayMin: dailyResp.Daily[0].TempMin,
		Hourly:   hourly,
		Daily:    daily,
	}
	log.Printf("[weather] 查询成功：%s %.4f,%.4f → %s %s℃", city, lat, lon, result.NowText, result.NowTemp)
	return result, nil
}

// getJSON 请求上游并把响应解析到 out
func (s *WeatherService) getJSON(path string, out any) error {
	url := "https://" + s.host + path
	resp, err := s.client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("上游 HTTP %d", resp.StatusCode)
	}
	return json.Unmarshal(body, out)
}

// formatHour 从上游 ISO 时间取 HH:MM（如 2026-10-16T14:00+08:00 → 14:00）
func formatHour(iso string) string {
	if t, err := time.Parse(time.RFC3339, iso); err == nil {
		return t.Format("15:04")
	}
	// 兜底：直接截取 "T" 后的 5 个字符
	if i := strings.Index(iso, "T"); i >= 0 && len(iso) >= i+6 {
		return iso[i+1 : i+6]
	}
	return iso
}
