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
	adminCtrl *controller.AdminController,
) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/heartbeat", heartbeatCtrl.Report)
	mux.HandleFunc("/api/devices", devicesCtrl.List)
	mux.HandleFunc("/api/access/verify", accessCtrl.Verify)
	mux.HandleFunc("/api/ping", pingCtrl.Ping)
	mux.HandleFunc("/api/admin/codes", adminCtrl.ListCodes)
	mux.HandleFunc("/api/admin/codes/generate", adminCtrl.GenerateCodes)

	// H5 在线宠物列表页（内置静态页面，与接口同源，免跨域）
	mux.HandleFunc("/online", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(web.OnlinePage)
	})
	// 统一后台管理页：/admin 在线宠物、/admin/codes 激活码管理（数据接口需 X-Admin-Token 鉴权）
	mux.HandleFunc("/admin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(web.AdminPetsPage)
	})
	mux.HandleFunc("/admin/codes", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(web.AdminCodesPage)
	})
	// 内置静态资源（Tabler 样式等，与接口同源）
	mux.Handle("/static/", http.FileServer(http.FS(web.StaticFS)))
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
