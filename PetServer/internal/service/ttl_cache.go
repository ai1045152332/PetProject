// internal/service/ttl_cache.go
// 极简 TTL 缓存：热搜 / 天气这类「短时间重复请求但不宜频繁打上游」的数据用。
// 只做进程内缓存（单实例部署），过期即视为未命中；并发安全。
package service

import (
	"sync"
	"time"
)

type ttlEntry[T any] struct {
	value     T
	expiresAt time.Time
	updatedAt time.Time
}

// TTLCache 带有效期的内存缓存。
type TTLCache[T any] struct {
	mu      sync.Mutex
	entries map[string]ttlEntry[T]
	ttl     time.Duration
}

// NewTTLCache 创建缓存；ttl <= 0 时退化为「不缓存」（每次都不命中）。
func NewTTLCache[T any](ttl time.Duration) *TTLCache[T] {
	return &TTLCache[T]{entries: make(map[string]ttlEntry[T]), ttl: ttl}
}

// Get 命中未过期条目时返回 (值, 写入时间, true)。
func (c *TTLCache[T]) Get(key string) (T, time.Time, bool) {
	var zero T
	if c == nil || c.ttl <= 0 {
		return zero, time.Time{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if !ok || time.Now().After(entry.expiresAt) {
		if ok {
			delete(c.entries, key) // 顺手清掉过期项，省得越攒越多
		}
		return zero, time.Time{}, false
	}
	return entry.value, entry.updatedAt, true
}

// Set 写入并重置有效期。
func (c *TTLCache[T]) Set(key string, value T) time.Time {
	if c == nil || c.ttl <= 0 {
		return time.Time{}
	}
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = ttlEntry[T]{value: value, expiresAt: now.Add(c.ttl), updatedAt: now}
	return now
}

// TTL 当前有效期（供接口把「缓存到什么时候」透给客户端）。
func (c *TTLCache[T]) TTL() time.Duration {
	if c == nil {
		return 0
	}
	return c.ttl
}
