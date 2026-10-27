// 依赖装配：按「存储 → 服务 → 控制器 → 路由」分层组装，供 main 启动 HTTP 服务
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"petserver/internal/controller"
	"petserver/internal/crypto"
	"petserver/internal/router"
	"petserver/internal/service"
	"petserver/internal/storage"
)

// deps 装配完成的服务依赖，handler 为可直接服务的根路由
type deps struct {
	handler http.Handler
	store   *storage.HeartbeatStore // 心跳存储，供后台清理任务使用
}

// buildDeps 组装各层依赖并返回根 handler 与清理函数（cleanup 关闭存储并落盘接口计数）。
// 初始化失败直接返回错误，由 main 统一 log.Fatalf 退出。
func buildDeps() (*deps, func(), error) {
	store, err := storage.NewHeartbeatStore("data/heartbeats.jsonl")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化心跳存储失败: %w", err)
	}
	snapshotStore, err := storage.NewDeviceSnapshotStore("data/devices.json")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化设备快照存储失败: %w", err)
	}
	heartbeatSvc := service.NewHeartbeatService(store, snapshotStore)

	// 好友与宠物消息：宠物号注册 + 好友关系 + 收件箱（云端本地 JSON，心跳拉取）
	socialStore, err := storage.NewSocialStore("data/social.json")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化好友消息存储失败: %w", err)
	}
	socialSvc := service.NewSocialService(socialStore)
	heartbeatCtrl := controller.NewHeartbeatController(heartbeatSvc, socialSvc)

	noteStore, err := storage.NewDeviceNoteStore("data/device_notes.json")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化设备备注存储失败: %w", err)
	}
	noteSvc := service.NewDeviceNoteService(noteStore)
	devicesCtrl := controller.NewDevicesController(heartbeatSvc, noteSvc, socialSvc)

	activationStore, err := storage.NewActivationStore("data/activation_codes.json")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化激活码存储失败: %w", err)
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
	adminPass := envOrDefault("PETSERVER_ADMIN_PASSWORD", os.Getenv("PETSERVER_ADMIN_TOKEN"))
	// 会话持久化：服务重启/重新部署后登录态不丢
	authSvc := service.NewAuthService(adminUser, adminPass, "data/sessions.json")

	// 应用层加密密钥：默认 data/private_key.pem，可用 PETSERVER_PRIVATE_KEY_PATH 覆盖
	keyPath := envOrDefault("PETSERVER_PRIVATE_KEY_PATH", "data/private_key.pem")
	keyPair, created, err := crypto.LoadOrCreate(keyPath)
	if err != nil {
		return nil, nil, fmt.Errorf("初始化加密密钥失败: %w", err)
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
	filesRoot := envOrDefault("PETSERVER_FILES_ROOT", ".")
	fileSvc, err := service.NewFileService(filesRoot)
	if err != nil {
		return nil, nil, fmt.Errorf("初始化文件管理服务失败: %w", err)
	}
	log.Printf("[files] 文件管理根目录: %s", fileSvc.Root())
	filesCtrl := controller.NewFileController(authSvc, fileSvc)

	// 背单词词库下发：JSON 放在 wordbank/ 目录（可用 PETSERVER_WORDBANK_DIR 覆盖），
	// 文件可在后台文件管理页维护，改词库无需重新发版
	wordbankDir := envOrDefault("PETSERVER_WORDBANK_DIR", "wordbank")
	wordbankSvc, err := service.NewWordBankService(wordbankDir)
	if err != nil {
		return nil, nil, fmt.Errorf("初始化词库服务失败: %w", err)
	}
	log.Printf("[wordbank] 词库目录: %s", wordbankSvc.Root())
	wordbankCtrl := controller.NewWordBankController(wordbankSvc)

	authCtrl := controller.NewAuthController(authSvc, keyPair)
	cryptoCtrl := controller.NewCryptoController(keyPair)
	systemSvc := service.NewSystemService()

	// 接口调用计数：内存累加 + 定期落盘（data/api_metrics.json），重启不丢累计
	metricsStore, err := storage.NewApiMetricsStore("data/api_metrics.json")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化接口计数存储失败: %w", err)
	}
	metricsSvc := service.NewMetricsService(metricsStore)
	metricsSvc.StartAutoFlush(30 * time.Second)

	adminCtrl := controller.NewAdminController(accessSvc, authSvc, noteSvc, systemSvc, heartbeatSvc, metricsSvc, socialSvc)

	// AI 生图与宠物图片
	imageObjects, err := storage.NewLocalPetImageObjects("data/pet-images/objects")
	if err != nil {
		return nil, nil, fmt.Errorf("初始化宠物图片对象存储失败: %w", err)
	}
	imageSvc, err := service.NewPetImageService("data/pet-images/libraries", imageObjects)
	if err != nil {
		return nil, nil, fmt.Errorf("初始化宠物图片服务失败: %w", err)
	}
	// AI 生图总次数按激活码配置：每个码各用各的 imageQuota，未开通即为 0（不再用全局默认）。
	imageSvc.SetImageQuotaResolver(accessSvc.ImageQuota)
	if generator := service.NewOpenRouterPetImageGenerator(os.Getenv("OPENROUTER_API_KEY"), os.Getenv("PETSERVER_OPENROUTER_IMAGE_MODEL")); generator != nil {
		imageSvc.SetGenerator(generator)
	} else {
		log.Printf("[pet-images] 未配置 OPENROUTER_API_KEY，上传/重试将返回 503，历史读取不受影响")
	}
	imageCtrl := controller.NewPetImageController(imageSvc, accessSvc, keyPair)

	// 好友/消息控制器：加密信封需 keyPair，故在密钥就绪后创建
	socialCtrl := controller.NewSocialController(socialSvc, keyPair)

	// ACME HTTP-01 验证目录（certbot webroot 模式写入 challenge 文件）
	acmeDir := envOrDefault("PETSERVER_ACME_DIR", "data/acme-challenges")
	if err := os.MkdirAll(acmeDir, 0o755); err != nil {
		return nil, nil, fmt.Errorf("创建 ACME 验证目录失败: %w", err)
	}

	handler := router.New(heartbeatCtrl, devicesCtrl, accessCtrl, pingCtrl, adminCtrl, authCtrl, cryptoCtrl,
		releaseCtrl, weatherCtrl, filesCtrl, wordbankCtrl, metricsSvc, acmeDir, imageCtrl, socialCtrl)

	cleanup := func() {
		imageSvc.Close()
		metricsSvc.Flush()
		store.Close()
	}
	return &deps{handler: handler, store: store}, cleanup, nil
}
