// internal/service/news_service.go
// 热搜服务：服务端统一抓「今日头条热榜」（失败兜底百度热搜）并做 TTL 缓存，
// 客户端只调 /api/news，不再各自直连上游、也不在本地缓存。
// 这样上游限流/改版只影响一处，多端（Swift / Electron）拿到的也是同一份榜单。
package service

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"

	"petserver/internal/model"
)

const (
	// newsTTL 热搜缓存有效期：10 分钟。热搜变化不快，10 分钟足够新，又能把上游压力压到 1/几十
	newsTTL = 10 * time.Minute
	// newsTimeout 单源请求超时
	newsTimeout = 8 * time.Second
	// newsTopN 只取前 N 条（客户端气泡与卡片都用不了太多）
	newsTopN = 10
)

const (
	toutiaoHotURL = "https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc"
	baiduHotURL   = "https://top.baidu.com/api/board?platform=wise&tab=realtime"
)

// NewsService 热搜聚合 + 缓存。
type NewsService struct {
	client *http.Client
	cache  *TTLCache[[]model.NewsItem]

	mu     sync.Mutex
	last   []model.NewsItem // 最近一次成功抓取（上游全挂时兜底，比让客户端空窗好）
	lastAt time.Time
	source string
}

// NewNewsService 创建热搜服务。
func NewNewsService() *NewsService {
	return &NewsService{
		client: &http.Client{Timeout: newsTimeout},
		cache:  NewTTLCache[[]model.NewsItem](newsTTL),
	}
}

// Hot 取热搜榜单：命中缓存直接返回；未命中则抓上游并回写缓存。
// 上游全部失败时退回「最近一次成功」的数据（标记 stale），实在没有才报错。
func (s *NewsService) Hot() (items []model.NewsItem, updatedAt time.Time, cached bool, stale bool, err error) {
	if hit, at, ok := s.cache.Get("hot"); ok {
		return hit, at, true, false, nil
	}

	fetched, source, ferr := s.fetch()
	if ferr != nil {
		// 上游失败：有上次成功的就先用着（stale），没有再报错
		s.mu.Lock()
		defer s.mu.Unlock()
		if len(s.last) > 0 {
			log.Printf("[news] 上游抓取失败(%v)，返回 %s 的旧榜单", ferr, s.lastAt.Format("15:04"))
			return s.last, s.lastAt, true, true, nil
		}
		return nil, time.Time{}, false, false, ferr
	}

	at := s.cache.Set("hot", fetched)
	s.mu.Lock()
	s.last = fetched
	s.lastAt = at
	s.source = source
	s.mu.Unlock()
	log.Printf("[news] 热搜已刷新：%d 条（来源 %s）", len(fetched), source)
	return fetched, at, false, false, nil
}

// TTL 缓存有效期（接口透传给客户端做展示）
func (s *NewsService) TTL() time.Duration { return newsTTL }

// fetch 依次尝试 头条 → 百度，返回首个成功的结果。
func (s *NewsService) fetch() ([]model.NewsItem, string, error) {
	if items, err := s.fetchToutiao(); err == nil && len(items) > 0 {
		return items, "toutiao", nil
	} else if err != nil {
		log.Printf("[news] 头条失败：%v，改用百度", err)
	}
	items, err := s.fetchBaidu()
	if err != nil {
		return nil, "", err
	}
	return items, "baidu", nil
}

func (s *NewsService) getJSON(rawURL string, out any) error {
	resp, err := s.client.Get(rawURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("上游 HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

// fetchToutiao 头条热榜：{"data":[{"Title":"...","Url":"..."}]}
func (s *NewsService) fetchToutiao() ([]model.NewsItem, error) {
	var payload struct {
		Data []struct {
			Title string `json:"Title"`
			URL   string `json:"Url"`
		} `json:"data"`
	}
	if err := s.getJSON(toutiaoHotURL, &payload); err != nil {
		return nil, err
	}
	items := make([]model.NewsItem, 0, newsTopN)
	for _, row := range payload.Data {
		if row.Title == "" {
			continue
		}
		items = append(items, model.NewsItem{Rank: len(items) + 1, Title: row.Title, URL: row.URL})
		if len(items) >= newsTopN {
			break
		}
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("头条返回空列表")
	}
	return items, nil
}

// fetchBaidu 百度热搜：data.cards[0].content（个别结构内层再套一层 content）
func (s *NewsService) fetchBaidu() ([]model.NewsItem, error) {
	var payload struct {
		Data struct {
			Cards []struct {
				Content []struct {
					Query   string `json:"query"`
					Word    string `json:"word"`
					Title   string `json:"title"`
					Content []struct {
						Query string `json:"query"`
						Word  string `json:"word"`
						Title string `json:"title"`
					} `json:"content"`
				} `json:"content"`
			} `json:"cards"`
		} `json:"data"`
	}
	if err := s.getJSON(baiduHotURL, &payload); err != nil {
		return nil, err
	}

	type baiduRow struct {
		Query string `json:"query"`
		Word  string `json:"word"`
		Title string `json:"title"`
	}
	rows := make([]baiduRow, 0, newsTopN)
	if len(payload.Data.Cards) > 0 {
		outer := payload.Data.Cards[0].Content
		// 「wise」端常见结构：外层只有一条、真正的列表在内层
		if len(outer) == 1 && len(outer[0].Content) > 0 {
			for _, inner := range outer[0].Content {
				rows = append(rows, baiduRow{Query: inner.Query, Word: inner.Word, Title: inner.Title})
			}
		} else {
			for _, row := range outer {
				rows = append(rows, baiduRow{Query: row.Query, Word: row.Word, Title: row.Title})
			}
		}
	}

	items := make([]model.NewsItem, 0, newsTopN)
	for _, row := range rows {
		title := row.Query
		if title == "" {
			title = row.Word
		}
		if title == "" {
			title = row.Title
		}
		if title == "" {
			continue
		}
		// 百度条目没有直达链接，用标题拼搜索页（与客户端原逻辑一致）
		items = append(items, model.NewsItem{
			Rank:  len(items) + 1,
			Title: title,
			URL:   "https://www.baidu.com/s?wd=" + url.QueryEscape(title),
		})
		if len(items) >= newsTopN {
			break
		}
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("百度返回空列表")
	}
	return items, nil
}
