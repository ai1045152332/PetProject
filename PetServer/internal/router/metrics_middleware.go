package router

import (
	"net/http"
	"time"

	"petserver/internal/service"
)

// statusRecorder 透传 ResponseWriter 并捕获最终状态码，供接口计数使用
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// metricsSkipPaths 不纳入统计的接口：统计页自身每 10 秒轮询一次，
// 若也计数会把它顶到榜首，淹掉客户端的真实流量
var metricsSkipPaths = map[string]bool{
	"/api/admin/metrics": true,
}

// metricsMiddleware 接口调用计数中间件：
// 在每个请求处理完后记录「接口、状态码分类、耗时」，不读取也不记录请求内容
func metricsMiddleware(svc *service.MetricsService, next http.Handler) http.Handler {
	if svc == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if metricsSkipPaths[r.URL.Path] {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		svc.Record(r.Method, r.URL.Path, rec.status, time.Since(start).Microseconds())
	})
}
