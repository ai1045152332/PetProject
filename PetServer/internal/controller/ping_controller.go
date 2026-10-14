package controller

import (
	"net/http"
	"time"
)

// PingController 连通性测试接口控制器
type PingController struct{}

// NewPingController 创建连通性测试控制器
func NewPingController() *PingController {
	return &PingController{}
}

// Ping 处理 GET /api/ping（供浏览器直接访问，测试服务可达性）
func (c *PingController) Ping(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	writeJSON(w, http.StatusOK, Response{
		Code: 0,
		Msg:  "ok",
		Data: map[string]any{
			"service":    "PetServer",
			"serverTime": time.Now().Format(time.RFC3339),
		},
	})
}
