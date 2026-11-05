package controller

import (
	"net/http"
	"time"

	"petserver/internal/model"
	"petserver/internal/service"
)

// NewsController 热搜接口：服务端抓取 + TTL 缓存后下发，客户端不再直连上游、也不本地缓存。
type NewsController struct {
	svc *service.NewsService
}

// NewNewsController 创建热搜控制器
func NewNewsController(svc *service.NewsService) *NewsController {
	return &NewsController{svc: svc}
}

// newsResponse 下发结构：榜单 + 抓取时间 + 缓存有效期，客户端据此决定何时再来取。
type newsResponse struct {
	Items     []model.NewsItem `json:"items"`
	UpdatedAt int64            `json:"updatedAt"` // 抓取时间（UnixMilli）
	TTLSec    int64            `json:"ttlSec"`    // 服务端缓存多久过期
	Cached    bool             `json:"cached"`    // 本次是否命中服务端缓存
	Stale     bool             `json:"stale"`     // 上游失败，返回的是旧榜单
}

// Hot 处理 GET /api/news
func (c *NewsController) Hot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	items, updatedAt, cached, stale, err := c.svc.Hot()
	if err != nil {
		writeJSON(w, http.StatusBadGateway, Response{Code: 502, Msg: "news fetch failed: " + err.Error()})
		return
	}
	if updatedAt.IsZero() {
		updatedAt = time.Now()
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: newsResponse{
		Items:     items,
		UpdatedAt: updatedAt.UnixMilli(),
		TTLSec:    int64(c.svc.TTL() / time.Second),
		Cached:    cached,
		Stale:     stale,
	}})
}
