// PetServer 入口：组装各层依赖并启动 HTTP 服务
package main

import (
	"crypto/tls"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"petserver/internal/controller"
	"petserver/internal/crypto"
	"petserver/internal/router"
	"petserver/internal/service"
	"petserver/internal/storage"
	"petserver/internal/tlsreloader"
)

// 心跳日志清理任务参数
const (
	cleanupInterval = 5 * time.Minute // 执行周期
	logRetention    = 5 * time.Minute // 日志保留窗口
)

func main() {
	// 监听地址可用 PETSERVER_LISTEN_ADDR 配置（公网部署常直接监听 :80，本地开发用默认 :8080）
	addr := os.Getenv("PETSERVER_LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}

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

	snapshotStore, err := storage.NewDeviceSnapshotStore("data/devices.json")
	if err != nil {
		log.Fatalf("初始化设备快照存储失败: %v", err)
	}
	heartbeatSvc := service.NewHeartbeatService(store, snapshotStore)
	heartbeatCtrl := controller.NewHeartbeatController(heartbeatSvc)

	noteStore, err := storage.NewDeviceNoteStore("data/device_notes.json")
	if err != nil {
		log.Fatalf("初始化设备备注存储失败: %v", err)
	}
	noteSvc := service.NewDeviceNoteService(noteStore)
	devicesCtrl := controller.NewDevicesController(heartbeatSvc, noteSvc)
	activationStore, err := storage.NewActivationStore("data/activation_codes.json")
	if err != nil {
		log.Fatalf("初始化激活码存储失败: %v", err)
	}
	accessSvc := service.NewAccessService(activationStore)
	pingCtrl := controller.NewPingController()

	// 天气服务：上游 Key 只存服务器环境变量（天气接口按量付费，不下发客户端）
	weatherSvc := service.NewWeatherService(os.Getenv("PETSERVER_QWEATHER_HOST"), os.Getenv("PETSERVER_QWEATHER_KEY"))
	weatherCtrl := controller.NewWeatherController(weatherSvc)
	if !weatherSvc.Enabled() {
		log.Printf("[weather] 未配置 PETSERVER_QWEATHER_KEY，/api/weather 将返回 503")
	}
	// 管理后台账号密码：PETSERVER_ADMIN_USER（默认 admin）+ PETSERVER_ADMIN_PASSWORD
	// 兼容旧的 PETSERVER_ADMIN_TOKEN（作为密码来源）
	adminUser := os.Getenv("PETSERVER_ADMIN_USER")
	adminPass := os.Getenv("PETSERVER_ADMIN_PASSWORD")
	if adminPass == "" {
		adminPass = os.Getenv("PETSERVER_ADMIN_TOKEN")
	}
	// 会话持久化：服务重启/重新部署后登录态不丢
	authSvc := service.NewAuthService(adminUser, adminPass, "data/sessions.json")
	// 应用层加密密钥：默认 data/private_key.pem，可用 PETSERVER_PRIVATE_KEY_PATH 覆盖
	keyPath := os.Getenv("PETSERVER_PRIVATE_KEY_PATH")
	if keyPath == "" {
		keyPath = "data/private_key.pem"
	}
	keyPair, created, err := crypto.LoadOrCreate(keyPath)
	if err != nil {
		log.Fatalf("初始化加密密钥失败: %v", err)
	}
	if created {
		log.Printf("[crypto] 已生成新的 RSA 密钥对: %s（请把公钥内置到客户端）", keyPath)
	}
	if pub, err := keyPair.PublicKeyBase64(); err == nil {
		log.Printf("[crypto] 服务端公钥(base64, RSA-OAEP-SHA256): %s", pub)
	}

	accessCtrl := controller.NewAccessController(accessSvc, keyPair)
	releaseSvc := service.NewReleaseService("dist")
	releaseCtrl := controller.NewReleaseController(releaseSvc)

	// 文件管理：默认锚定服务工作目录（线上为 /opt/petserver），可同时浏览 data/ 与 dist/（安装包）；
	// 敏感文件（.env/.pem/.key/sessions.json）在 FileService 内已禁止预览与删除。可用 PETSERVER_FILES_ROOT 覆盖。
	filesRoot := os.Getenv("PETSERVER_FILES_ROOT")
	if filesRoot == "" {
		filesRoot = "."
	}
	fileSvc, err := service.NewFileService(filesRoot)
	if err != nil {
		log.Fatalf("初始化文件管理服务失败: %v", err)
	}
	log.Printf("[files] 文件管理根目录: %s", fileSvc.Root())
	filesCtrl := controller.NewFileController(authSvc, fileSvc)

	// 背单词词库下发：JSON 放在 wordbank/ 目录（可用 PETSERVER_WORDBANK_DIR 覆盖），
	// 文件可在后台文件管理页维护，改词库无需重新发版
	wordbankDir := os.Getenv("PETSERVER_WORDBANK_DIR")
	if wordbankDir == "" {
		wordbankDir = "wordbank"
	}
	wordbankSvc, err := service.NewWordBankService(wordbankDir)
	if err != nil {
		log.Fatalf("初始化词库服务失败: %v", err)
	}
	log.Printf("[wordbank] 词库目录: %s", wordbankSvc.Root())
	wordbankCtrl := controller.NewWordBankController(wordbankSvc)

	authCtrl := controller.NewAuthController(authSvc, keyPair)
	cryptoCtrl := controller.NewCryptoController(keyPair)
	systemSvc := service.NewSystemService()

	// 接口调用计数：内存累加 + 定期落盘（data/api_metrics.json），重启不丢累计
	metricsStore, err := storage.NewApiMetricsStore("data/api_metrics.json")
	if err != nil {
		log.Fatalf("初始化接口计数存储失败: %v", err)
	}
	metricsSvc := service.NewMetricsService(metricsStore)
	metricsSvc.StartAutoFlush(30 * time.Second)
	defer metricsSvc.Flush()

	adminCtrl := controller.NewAdminController(accessSvc, authSvc, noteSvc, systemSvc, heartbeatSvc, metricsSvc)
	imageObjects, err := storage.NewLocalPetImageObjects("data/pet-images/objects")
	if err != nil {
		log.Fatal(err)
	}
	imageSvc, err := service.NewPetImageService("data/pet-images/libraries", imageObjects)
	if err != nil {
		log.Fatal(err)
	}
	if generator := service.NewOpenRouterPetImageGenerator(os.Getenv("OPENROUTER_API_KEY"), os.Getenv("PETSERVER_OPENROUTER_IMAGE_MODEL")); generator != nil {
		imageSvc.SetGenerator(generator)
	} else {
		log.Printf("[pet-images] 未配置 OPENROUTER_API_KEY，上传/重试将返回 503，历史读取不受影响")
	}
	defer imageSvc.Close()
	imageCtrl := controller.NewPetImageController(imageSvc, accessSvc, keyPair)

	// ACME HTTP-01 验证目录（certbot webroot 模式写入 challenge 文件）
	acmeDir := os.Getenv("PETSERVER_ACME_DIR")
	if acmeDir == "" {
		acmeDir = "data/acme-challenges"
	}
	_ = os.MkdirAll(acmeDir, 0o755)
	handler := router.New(heartbeatCtrl, devicesCtrl, accessCtrl, pingCtrl, adminCtrl, authCtrl, cryptoCtrl, releaseCtrl, weatherCtrl, filesCtrl, wordbankCtrl, metricsSvc, acmeDir, imageCtrl)

	// HTTPS：证书/私钥文件存在时启用 443 监听，证书更新后自动热加载（配合 certbot 续期）
	tlsCert := os.Getenv("PETSERVER_TLS_CERT")
	tlsKey := os.Getenv("PETSERVER_TLS_KEY")
	if tlsCert == "" {
		tlsCert = "tls/fullchain.pem"
	}
	if tlsKey == "" {
		tlsKey = "tls/privkey.pem"
	}
	tlsAddr := os.Getenv("PETSERVER_TLS_ADDR")
	if tlsAddr == "" {
		tlsAddr = ":443"
	}
	if _, err := os.Stat(tlsCert); err == nil {
		if reloader, err := tlsreloader.New(tlsCert, tlsKey); err != nil {
			log.Printf("[tls] HTTPS 未启用（证书加载失败）: %v", err)
		} else {
			tlsLn, err := net.Listen("tcp", tlsAddr)
			if err != nil {
				log.Printf("[tls] HTTPS 未启用（%s 监听失败）: %v", tlsAddr, err)
			} else {
				go func() {
					srv := &http.Server{Handler: handler}
					if err := srv.Serve(tls.NewListener(tlsLn, &tls.Config{GetCertificate: reloader.GetCertificate})); err != nil {
						log.Printf("[tls] HTTPS 服务异常退出: %v", err)
					}
				}()
				log.Printf("[tls] HTTPS 已启用，监听 %s（证书热加载: %s）", tlsAddr, tlsCert)
			}
		}
	} else {
		log.Printf("[tls] HTTPS 未启用（未找到证书 %s）", tlsCert)
	}

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
