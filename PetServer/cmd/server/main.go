// PetServer 入口：组装各层依赖并启动 HTTP 服务
// 依赖装配见 deps.go，后台清理任务见 cleanup.go
package main

import (
	"log"
	"net"
	"net/http"
)

func main() {
	// 先占住端口，再初始化存储/后台任务：
	// 若端口已被占用，直接失败退出，绝不会执行清理任务，
	// 避免「端口被占 → log.Fatalf(os.Exit) 强杀后台 goroutine → 清理临时文件残留」
	addr := listenAddr()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("服务启动失败（端口 %s 可能被占用）: %v", addr, err)
	}
	defer ln.Close()
	log.Printf("PetServer 启动，监听 %s", ln.Addr())

	// 依赖组装：storage → service → controller → router
	deps, cleanup, err := buildDeps()
	if err != nil {
		log.Fatalf("服务初始化失败: %v", err)
	}
	// 关闭存储并落盘接口计数（正常退出时执行；init 失败发生在 buildDeps 内部，尚未注册）
	defer cleanup()

	// 后台任务：定期清理过期心跳日志
	startHeartbeatLogCleanup(deps.store)

	// HTTPS：证书存在时另行监听 443
	startHTTPSServer(deps.handler)

	if err := http.Serve(ln, deps.handler); err != nil {
		log.Fatalf("服务异常退出: %v", err)
	}
}

// listenAddr HTTP 监听地址：公网部署常直接监听 :80（PETSERVER_LISTEN_ADDR），本地开发用默认 :8080
func listenAddr() string {
	return envOrDefault("PETSERVER_LISTEN_ADDR", ":8080")
}
