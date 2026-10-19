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
	authCtrl *controller.AuthController,
	cryptoCtrl *controller.CryptoController,
	releaseCtrl *controller.ReleaseController,
	weatherCtrl *controller.WeatherController,
	filesCtrl *controller.FileController,
) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/heartbeat", heartbeatCtrl.Report)
	mux.HandleFunc("/api/devices", devicesCtrl.List)
	mux.HandleFunc("/api/access/verify", accessCtrl.Verify)
	mux.HandleFunc("/api/ping", pingCtrl.Ping)
	mux.HandleFunc("/api/weather", weatherCtrl.Query)
	mux.HandleFunc("/api/admin/codes", adminCtrl.ListCodes)
	mux.HandleFunc("/api/admin/codes/generate", adminCtrl.GenerateCodes)
	mux.HandleFunc("/api/admin/codes/unbind", adminCtrl.UnbindCodes)
	mux.HandleFunc("/api/admin/codes/delete", adminCtrl.DeleteCodes)
	mux.HandleFunc("/api/admin/login", authCtrl.Login)
	mux.HandleFunc("/api/admin/logout", authCtrl.Logout)
	mux.HandleFunc("/api/crypto/pubkey", cryptoCtrl.PubKey)
	mux.HandleFunc("/api/admin/devices/note", adminCtrl.SetDeviceNote)
	mux.HandleFunc("/api/admin/files/list", filesCtrl.List)
	mux.HandleFunc("/api/admin/files/preview", filesCtrl.Preview)
	mux.HandleFunc("/api/admin/files/delete", filesCtrl.Delete)
	mux.HandleFunc("/api/app/latest", releaseCtrl.Latest)
	mux.HandleFunc("/download/", releaseCtrl.Download)

	// H5 在线宠物列表页（内置静态页面，与接口同源，免跨域）
	mux.HandleFunc("/online", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(web.OnlinePage)
	})
	// 统一后台管理页：/admin/login 登录页、/admin 在线宠物、/admin/codes 激活码管理
	// 页面不缓存：避免部署新版本后浏览器仍展示旧 HTML
	noCache := func(w http.ResponseWriter) {
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
		w.Header().Set("Pragma", "no-cache")
	}
	_ = noCache
	mux.HandleFunc("/admin/login", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		noCache(w)
		w.Write(web.AdminLoginPage)
	})
	mux.HandleFunc("/admin", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		noCache(w)
		w.Write(web.AdminPetsPage)
	})
	mux.HandleFunc("/admin/codes", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		noCache(w)
		w.Write(web.AdminCodesPage)
	})
	// 后台管理：文件管理页（查看/预览/删除服务器文件）
	mux.HandleFunc("/admin/files", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		noCache(w)
		w.Write(web.AdminFilesPage)
	})
	// 内置静态资源（Tabler 样式等，与接口同源）
	mux.Handle("/static/", http.FileServer(http.FS(web.StaticFS)))
	// 根路径跳转后台管理（手机版在线宠物页保留在 /online）
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.Redirect(w, r, "/admin", http.StatusFound)
	})
	return mux
}
