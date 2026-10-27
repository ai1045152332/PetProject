// 后台任务与 HTTPS 监听：心跳日志定期清理、TLS 热加载服务
package main

import (
	"crypto/tls"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"petserver/internal/storage"
	"petserver/internal/tlsreloader"
)

// 心跳日志清理任务参数
const (
	cleanupInterval = 5 * time.Minute // 执行周期
	logRetention    = 5 * time.Minute // 日志保留窗口
)

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

// startHTTPSServer 证书/私钥存在时启用 443 监听，证书更新后自动热加载（配合 certbot 续期）。
// 任何一步不满足都只记日志、不中断主服务。
func startHTTPSServer(handler http.Handler) {
	tlsCert := envOrDefault("PETSERVER_TLS_CERT", "tls/fullchain.pem")
	tlsKey := envOrDefault("PETSERVER_TLS_KEY", "tls/privkey.pem")
	if _, err := os.Stat(tlsCert); err != nil {
		log.Printf("[tls] HTTPS 未启用（未找到证书 %s）", tlsCert)
		return
	}
	reloader, err := tlsreloader.New(tlsCert, tlsKey)
	if err != nil {
		log.Printf("[tls] HTTPS 未启用（证书加载失败）: %v", err)
		return
	}
	tlsAddr := envOrDefault("PETSERVER_TLS_ADDR", ":443")
	tlsLn, err := net.Listen("tcp", tlsAddr)
	if err != nil {
		log.Printf("[tls] HTTPS 未启用（%s 监听失败）: %v", tlsAddr, err)
		return
	}
	go func() {
		srv := &http.Server{Handler: handler}
		if err := srv.Serve(tls.NewListener(tlsLn, &tls.Config{GetCertificate: reloader.GetCertificate})); err != nil {
			log.Printf("[tls] HTTPS 服务异常退出: %v", err)
		}
	}()
	log.Printf("[tls] HTTPS 已启用，监听 %s（证书热加载: %s）", tlsAddr, tlsCert)
}

// envOrDefault 读取环境变量，为空时返回默认值
func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
