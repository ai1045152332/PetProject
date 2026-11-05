package service

import "testing"

func TestWeatherCacheKeyPrefersCity(t *testing.T) {
	if got := weatherCacheKey("北京", 39.9042, 116.4074); got != "city:北京" {
		t.Fatalf("有城市时应按城市做 key，实际 %q", got)
	}
	// 前后空格 / 大小写不该各存一份
	if a, b := weatherCacheKey("Shanghai", 31.2, 121.5), weatherCacheKey(" shanghai ", 31.2, 121.5); a != b {
		t.Fatalf("城市名应归一化：%q vs %q", a, b)
	}
}

func TestWeatherCacheKeyFallsBackToCoords(t *testing.T) {
	if got := weatherCacheKey("   ", 39.9042, 116.4074); got != "coord:39.90,116.41" {
		t.Fatalf("无城市时应按坐标（两位小数）做 key，实际 %q", got)
	}
}
