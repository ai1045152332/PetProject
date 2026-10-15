// PetServer 入口：组装各层依赖并启动 HTTP 服务
package main

import (
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"petserver/internal/controller"
	"petserver/internal/router"
	"petserver/internal/service"
	"petserver/internal/storage"
)

// 心跳日志清理任务参数
const (
	cleanupInterval = 5 * time.Minute // 执行周期
	logRetention    = 5 * time.Minute // 日志保留窗口
)

func main() {
	addr := ":8080"

	// 先占住端口，再初始化存储/后台任务：
	// 若端口已被占用，直接失败退出，绝不会执行清理任务，
	// 避免「端口被占 → log.Fatalf(os.Exit) 强杀后台 goroutine → 清理临时文件残留」
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("服务启动失败（端口 %s 可能被占用）: %v", addr, err)
	}
	defer ln.Close()
	log.Printf("PetServer 启动，监听 %s", addr)

	// 依赖组装：storage → service → controller → router
	store, err := storage.NewHeartbeatStore("data/heartbeats.jsonl")
	if err != nil {
		log.Fatalf("初始化心跳存储失败: %v", err)
	}
	defer store.Close()

	heartbeatSvc := service.NewHeartbeatService(store)
	heartbeatCtrl := controller.NewHeartbeatController(heartbeatSvc)
	devicesCtrl := controller.NewDevicesController(heartbeatSvc)
	activationStore, err := storage.NewActivationStore("data/activation_codes.json")
	if err != nil {
		log.Fatalf("初始化激活码存储失败: %v", err)
	}
	accessSvc := service.NewAccessService(activationStore)
	accessCtrl := controller.NewAccessController(accessSvc)
	pingCtrl := controller.NewPingController()
	adminCtrl := controller.NewAdminController(accessSvc, os.Getenv("PETSERVER_ADMIN_TOKEN"))
	handler := router.New(heartbeatCtrl, devicesCtrl, accessCtrl, pingCtrl, adminCtrl)

	// 后台任务：定期清理过期心跳日志
	startHeartbeatLogCleanup(store)

	if err := http.Serve(ln, handler); err != nil {
		log.Fatalf("服务异常退出: %v", err)
	}
}

// startHeartbeatLogCleanup 启动心跳日志定期清理任务：
// 启动时先立即清理一次历史积压，之后每 cleanupInterval 执行一次，
// 只保留最近 logRetention 窗口内的日志。
func startHeartbeatLogCleanup(store *storage.HeartbeatStore) {
	go func() {
		ticker := time.NewTicker(cleanupInterval)
		defer ticker.Stop()

		run := func() {
			cutoff := time.Now().Add(-logRetention)
			removed, err := store.CleanupBefore(cutoff)
			switch {
			case err != nil:
				log.Printf("[cleanup] 心跳日志清理失败: %v", err)
			case removed > 0:
				log.Printf("[cleanup] 已清理 %d 条过期心跳日志（保留最近 %s）", removed, logRetention)
			}
		}

		run()
		for range ticker.C {
			run()
		}
	}()
	log.Printf("[cleanup] 心跳日志清理任务已启动：每 %s 执行一次，保留最近 %s", cleanupInterval, logRetention)
}
