package service

import (
	"testing"
	"time"
)

func TestTTLCacheHitAndExpire(t *testing.T) {
	c := NewTTLCache[string](50 * time.Millisecond)
	if _, _, ok := c.Get("k"); ok {
		t.Fatal("空缓存不应命中")
	}

	at := c.Set("k", "v1")
	if at.IsZero() {
		t.Fatal("Set 应返回写入时间")
	}
	v, gotAt, ok := c.Get("k")
	if !ok || v != "v1" {
		t.Fatalf("刚写入应命中，实际 %q %v", v, ok)
	}
	if !gotAt.Equal(at) {
		t.Fatalf("写入时间应一致：%v vs %v", gotAt, at)
	}

	time.Sleep(70 * time.Millisecond)
	if _, _, ok := c.Get("k"); ok {
		t.Fatal("过期后不应命中")
	}
}

func TestTTLCacheDisabledWhenZeroTTL(t *testing.T) {
	c := NewTTLCache[int](0)
	c.Set("k", 1)
	if _, _, ok := c.Get("k"); ok {
		t.Fatal("ttl<=0 时应视作不缓存")
	}
}

func TestTTLCacheKeyIsolation(t *testing.T) {
	c := NewTTLCache[int](time.Minute)
	c.Set("a", 1)
	c.Set("b", 2)
	if v, _, _ := c.Get("a"); v != 1 {
		t.Fatalf("a 应为 1，实际 %d", v)
	}
	if v, _, _ := c.Get("b"); v != 2 {
		t.Fatalf("b 应为 2，实际 %d", v)
	}
}
