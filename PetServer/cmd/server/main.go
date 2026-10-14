// PetServer 入口：组装各层依赖并启动 HTTP 服务
package main

import (
	"log"
	"net/http"

	"petserver/internal/controller"
	"petserver/internal/router"
	"petserver/internal/service"
	"petserver/internal/storage"
)

func main() {
	// 依赖组装：storage → service → controller → router
	store, err := storage.NewHeartbeatStore("data/heartbeats.jsonl")
	if err != nil {
		log.Fatalf("初始化心跳存储失败: %v", err)
	}
	defer store.Close()

	heartbeatSvc := service.NewHeartbeatService(store)
	heartbeatCtrl := controller.NewHeartbeatController(heartbeatSvc)
	accessSvc := service.NewAccessService()
	accessCtrl := controller.NewAccessController(accessSvc)
	handler := router.New(heartbeatCtrl, accessCtrl)

	addr := ":8080"
	log.Printf("PetServer 启动，监听 %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("服务启动失败: %v", err)
	}
}
