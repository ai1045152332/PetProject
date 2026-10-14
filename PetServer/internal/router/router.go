// Package router 负责路由注册
package router

import (
	"net/http"

	"petserver/internal/controller"
)

// New 注册全部路由，返回根 Handler
func New(heartbeatCtrl *controller.HeartbeatController, accessCtrl *controller.AccessController, pingCtrl *controller.PingController) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/heartbeat", heartbeatCtrl.Report)
	mux.HandleFunc("/api/access/verify", accessCtrl.Verify)
	mux.HandleFunc("/api/ping", pingCtrl.Ping)
	return mux
}
