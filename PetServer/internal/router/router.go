// Package router 负责路由注册
package router

import (
	"net/http"

	"petserver/internal/controller"
	"petserver/internal/web"
)

// New 注册全部路由，返回根 Handler
func New(
	heartbeatCtrl *controller.HeartbeatController,
	devicesCtrl *controller.DevicesController,
	accessCtrl *controller.AccessController,
	pingCtrl *controller.PingController,
) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/heartbeat", heartbeatCtrl.Report)
	mux.HandleFunc("/api/devices", devicesCtrl.List)
	mux.HandleFunc("/api/access/verify", accessCtrl.Verify)
	mux.HandleFunc("/api/ping", pingCtrl.Ping)

	// H5 在线宠物列表页（内置静态页面，与接口同源，免跨域）
	mux.HandleFunc("/online", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(web.OnlinePage)
	})
	// 根路径也直接展示列表页，方便手机扫码/输入 IP 访问
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(web.OnlinePage)
	})
	return mux
}
