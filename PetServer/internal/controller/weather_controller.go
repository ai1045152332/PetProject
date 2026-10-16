package controller

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"petserver/internal/service"
)

// 限流参数：单设备每小时最多查询次数（天气接口按量付费）
const (
	weatherRateLimit  = 30
	weatherRateWindow = time.Hour
)

// WeatherController 天气查询接口（服务端代持上游 Key）
type WeatherController struct {
	svc *service.WeatherService
}

// NewWeatherController 创建天气控制器
func NewWeatherController(svc *service.WeatherService) *WeatherController {
	return &WeatherController{svc: svc}
}

// Query 处理 GET /api/weather?lat=&lon=&city=&deviceId=
func (c *WeatherController) Query(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if !c.svc.Enabled() {
		writeJSON(w, http.StatusServiceUnavailable, Response{Code: 503, Msg: "weather service not configured"})
		return
	}

	q := r.URL.Query()
	lat, errLat := strconv.ParseFloat(q.Get("lat"), 64)
	lon, errLon := strconv.ParseFloat(q.Get("lon"), 64)
	if errLat != nil || errLon != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing or invalid lat/lon"})
		return
	}

	// 限流标识：优先设备 ID，其次来源 IP
	ident := strings.TrimSpace(q.Get("deviceId"))
	if ident == "" {
		ident = r.RemoteAddr
	}
	if !c.svc.Allow(ident, weatherRateLimit, weatherRateWindow) {
		writeJSON(w, http.StatusTooManyRequests, Response{Code: 429, Msg: "too many requests, try later"})
		return
	}

	city := strings.TrimSpace(q.Get("city"))
	result, err := c.svc.Fetch(city, lat, lon)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, Response{Code: 502, Msg: "weather fetch failed: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: result})
}
