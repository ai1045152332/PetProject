// Package router 负责路由注册
package router

import (
	"bytes"
	"compress/gzip"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"

	"petserver/internal/controller"
	"petserver/internal/service"
	"petserver/internal/web"
)

// 静态资源压缩缓存：文件小且固定，首次请求压缩后常驻内存
var (
	staticCacheMu sync.RWMutex
	staticCache   = map[string][]byte{}
)

func contentTypeFor(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".css":
		return "text/css; charset=utf-8"
	case ".js":
		return "application/javascript; charset=utf-8"
	case ".html":
		return "text/html; charset=utf-8"
	case ".png":
		return "image/png"
	case ".svg":
		return "image/svg+xml"
	default:
		return "application/octet-stream"
	}
}

// serveStatic 提供内置静态资源：gzip 压缩 + 一周强缓存（链路差时显著减少传输量）
func serveStatic(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/static/")
	if name == "" || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}

	data, err := fs.ReadFile(web.StaticFS, "static/"+name)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Content-Type", contentTypeFor(name))
	w.Header().Set("Cache-Control", "public, max-age=604800, immutable")
	w.Header().Set("Vary", "Accept-Encoding")

	if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Write(data)
		return
	}

	staticCacheMu.RLock()
	gz, ok := staticCache[name]
	staticCacheMu.RUnlock()
	if !ok {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		_, _ = zw.Write(data)
		_ = zw.Close()
		gz = buf.Bytes()
		staticCacheMu.Lock()
		staticCache[name] = gz
		staticCacheMu.Unlock()
	}

	w.Header().Set("Content-Encoding", "gzip")
	w.Write(gz)
}

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
	wordbankCtrl *controller.WordBankController,
	metricsSvc *service.MetricsService,
	acmeDir string,
	petImages *controller.PetImageController,
	socialCtrl *controller.SocialController,
) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/pet-images/", petImages.Handle)
	mux.HandleFunc("/api/heartbeat", heartbeatCtrl.Report)
	mux.HandleFunc("/api/devices", devicesCtrl.List)
	// 好友与宠物消息（register/add/list/remove/send）
	mux.HandleFunc("/api/social/", socialCtrl.Handle)
	mux.HandleFunc("/api/access/verify", accessCtrl.Verify)
	mux.HandleFunc("/api/ping", pingCtrl.Ping)
	mux.HandleFunc("/api/weather", weatherCtrl.Query)
	mux.HandleFunc("/api/admin/codes", adminCtrl.ListCodes)
	mux.HandleFunc("/api/admin/codes/generate", adminCtrl.GenerateCodes)
	mux.HandleFunc("/api/admin/codes/unbind", adminCtrl.UnbindCodes)
	mux.HandleFunc("/api/admin/codes/delete", adminCtrl.DeleteCodes)
	mux.HandleFunc("/api/admin/codes/quota", adminCtrl.SetCodeQuota)
	mux.HandleFunc("/api/admin/login", authCtrl.Login)
	mux.HandleFunc("/api/admin/logout", authCtrl.Logout)
	mux.HandleFunc("/api/crypto/pubkey", cryptoCtrl.PubKey)
	mux.HandleFunc("/api/admin/devices/note", adminCtrl.SetDeviceNote)
	mux.HandleFunc("/api/admin/devices/delete", adminCtrl.DeleteDevice)
	mux.HandleFunc("/api/admin/system/status", adminCtrl.SystemStatus)
	// 接口调用统计（需登录）：查看各接口被调用次数/失败数/耗时，可清零重新计数
	mux.HandleFunc("/api/admin/metrics", adminCtrl.ApiMetrics)
	mux.HandleFunc("/api/admin/metrics/reset", adminCtrl.ResetApiMetrics)
	mux.HandleFunc("/api/admin/files/list", filesCtrl.List)
	mux.HandleFunc("/api/admin/files/preview", filesCtrl.Preview)
	mux.HandleFunc("/api/admin/files/download", filesCtrl.Download)
	mux.HandleFunc("/api/admin/files/delete", filesCtrl.Delete)
	mux.HandleFunc("/api/app/latest", releaseCtrl.Latest)
	mux.HandleFunc("/download/", releaseCtrl.Download)
	// 背单词词库下发（免登录）：列表用于增量判断，get 返回词库 JSON 原文
	mux.HandleFunc("/api/wordbank/list", wordbankCtrl.List)
	mux.HandleFunc("/api/wordbank/get", wordbankCtrl.Get)
	// ACME HTTP-01 验证（Let's Encrypt 签发/续期），从磁盘目录读取 challenge 文件
	if acmeDir != "" {
		mux.HandleFunc("/.well-known/acme-challenge/", func(w http.ResponseWriter, r *http.Request) {
			name := strings.TrimPrefix(r.URL.Path, "/.well-known/acme-challenge/")
			if name == "" || strings.Contains(name, "..") || strings.ContainsAny(name, "/\\") {
				http.NotFound(w, r)
				return
			}
			// 标准 webroot 语义：URL 路径映射到 acmeDir 下的同名文件
			// （certbot 会写入 <webroot>/.well-known/acme-challenge/<token>）
			full := filepath.Join(acmeDir, filepath.Clean("/"+r.URL.Path))
			if !strings.HasPrefix(full, filepath.Clean(acmeDir)+string(os.PathSeparator)) {
				http.NotFound(w, r)
				return
			}
			data, err := os.ReadFile(full)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/plain")
			w.Write(data)
		})
	}

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
	// 后台管理：文件管理页（查看/预览/下载/删除服务器文件）
	mux.HandleFunc("/admin/files", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		noCache(w)
		w.Write(web.AdminFilesPage)
	})
	// 后台管理：服务器状态页（CPU/内存/网络流量实时监控）
	mux.HandleFunc("/admin/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		noCache(w)
		w.Write(web.AdminStatusPage)
	})
	// 内置静态资源（Tabler 样式等）：gzip + 长缓存，链路上只需传输一次
	mux.HandleFunc("/static/", serveStatic)
	// 官网落地页：根路径 / 直接托管嵌入的静态站点（index.html + assets），后台管理保留在 /admin
	siteFS, err := fs.Sub(web.SiteFS, "site")
	if err != nil {
		panic("加载内置官网失败: " + err.Error())
	}
	siteHandler := http.FileServer(http.FS(siteFS))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 官网 HTML 不缓存：避免部署新版本后浏览器仍用旧页面，导致下载链接指向过期版本；图片等资源仍可正常缓存
		if r.URL.Path == "/" || strings.HasSuffix(r.URL.Path, ".html") {
			noCache(w)
		}
		siteHandler.ServeHTTP(w, r)
	}))
	// 最外层挂接口计数：所有请求（含 404/405）都会被统计到
	return metricsMiddleware(metricsSvc, mux)
}
