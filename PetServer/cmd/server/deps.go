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
	"petserver/internal/petimage"
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

	// 好友与宠物消息：宠物号注册 + 好友关系 + 收件箱（SQLite，心跳拉取）
	socialRepo, err := openSocialRepo()
	if err != nil {
		return nil, nil, err
	}
	socialSvc := service.NewSocialService(socialRepo)
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
	imageSvc, err := petimage.NewPetImageService("data/pet-images/libraries", imageObjects)
	if err != nil {
		return nil, nil, fmt.Errorf("初始化宠物图片服务失败: %w", err)
	}
	// AI 生图总次数按激活码配置：每个码各用各的 imageQuota，未开通即为 0（不再用全局默认）。
	imageSvc.SetImageQuotaResolver(accessSvc.ImageQuota)
	// 生图管线写死为 Seedream，密钥只从服务器配置文件（/opt/petserver/petserver.env）读，不进源码：
	// 配了 PETSERVER_ARK_API_KEY 就直连火山方舟官方 Seedream 5.0；否则回退 OpenRouter 中转的
	// bytedance-seed/seedream-4.5（复用已有的 OPENROUTER_API_KEY）。两个 Key 都没配才关掉生图入口。
	// 模型名可用 PETSERVER_ARK_IMAGE_MODEL / PETSERVER_OPENROUTER_IMAGE_MODEL 覆盖，留空即用各自默认。
	if ark := petimage.NewArkPetImageGenerator(os.Getenv("PETSERVER_ARK_API_KEY"), os.Getenv("PETSERVER_ARK_IMAGE_MODEL")); ark != nil {
		imageSvc.SetGenerator(ark)
		log.Printf("[pet-images] 生图走 Seedream 官方（ARK），模型: %s", ark.Model())
	} else if openRouter := petimage.NewOpenRouterPetImageGenerator(os.Getenv("OPENROUTER_API_KEY"), os.Getenv("PETSERVER_OPENROUTER_IMAGE_MODEL")); openRouter != nil {
		imageSvc.SetGenerator(openRouter)
		// 明确告警：回退管线依赖 OpenRouter Key 仍然有效，一旦过期所有生图都会以 401 失败。
		// 这类失败只体现在客户端气泡里，以前线上从不记日志，导致漏配 ARK 几周无人察觉。
		log.Printf("[pet-images][WARN] 未配置 PETSERVER_ARK_API_KEY，生图回退 OpenRouter 上的 Seedream，模型: %s；请确认 %s 里的 OPENROUTER_API_KEY 仍在有效期内", openRouter.Model(), "/opt/petserver/petserver.env")
	} else {
		log.Printf("[pet-images][WARN] 未配置 PETSERVER_ARK_API_KEY 与 OPENROUTER_API_KEY，生图接口未启用，上传/重试将返回 503（历史读取不受影响）")
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
		_ = socialRepo.Close()
	}
	return &deps{handler: handler, store: store}, cleanup, nil
}

// legacySocialJSONPath 旧版好友与消息的单 JSON 存储（仅首次启用 SQLite 时作为导入来源）
const legacySocialJSONPath = "data/social.json"

// openSocialRepo 打开好友与消息的 SQLite 库（默认 data/petserver.db，可用 PETSERVER_DB_PATH 覆盖）。
// 库不存在会自动建表；首次启用时把旧 data/social.json 原样搬进来，宠物号与未读消息都保持不变。
func openSocialRepo() (*storage.SocialSQLite, error) {
	path := envOrDefault("PETSERVER_DB_PATH", "data/petserver.db")
	repo, err := storage.NewSocialSQLite(path, storage.DefaultFirstPetNo)
	if err != nil {
		return nil, fmt.Errorf("初始化好友消息库失败: %w", err)
	}
	if err := importLegacySocial(repo); err != nil {
		_ = repo.Close()
		return nil, err
	}
	log.Printf("[social] 好友与消息存储: SQLite %s", path)
	return repo, nil
}

// importLegacySocial 把旧 JSON 状态导入 SQLite：只在「空库 + 有旧数据」时跑。
// 旧文件原地保留（不改名、不删除）：回滚到旧版本二进制时它还能读到自己的宠物号；
// 库文件意外丢失时，重启会从它重建，不至于把所有设备的号段归零。
func importLegacySocial(repo *storage.SocialSQLite) error {
	hasDevices, err := repo.HasDevices()
	if err != nil {
		return fmt.Errorf("检查好友库现状失败: %w", err)
	}
	if hasDevices {
		return nil // 已经在用 SQLite，不碰运行期数据
	}

	if info, err := os.Stat(legacySocialJSONPath); err != nil || info.Size() == 0 {
		return nil // 没有旧数据（全新部署）
	}
	legacy, err := storage.NewSocialStore(legacySocialJSONPath)
	if err != nil {
		return fmt.Errorf("初始化旧好友存储失败: %w", err)
	}
	state, err := legacy.Load()
	if err != nil {
		// 旧文件坏了就启动失败，交给部署脚本回滚，避免默默给老设备重发宠物号
		return fmt.Errorf("读取旧好友数据失败: %w", err)
	}
	stats, err := repo.ImportSocialState(state)
	if err != nil {
		return fmt.Errorf("导入旧好友数据失败: %w", err)
	}
	if stats.Devices == 0 && stats.Friends == 0 && stats.Requests == 0 && stats.Messages == 0 && stats.History == 0 {
		return nil // 旧文件本就是空的
	}
	log.Printf("[social] 已从 social.json 导入：设备 %d、好友 %d、申请 %d、消息 %d、留痕 %d（旧文件保留不动）",
		stats.Devices, stats.Friends, stats.Requests, stats.Messages, stats.History)
	return nil
}
