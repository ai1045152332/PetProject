package controller

import (
	"net/http"
	"path/filepath"

	"petserver/internal/service"
)

// ReleaseController 客户端更新接口
type ReleaseController struct {
	svc *service.ReleaseService
}

// NewReleaseController 创建更新控制器
func NewReleaseController(svc *service.ReleaseService) *ReleaseController {
	return &ReleaseController{svc: svc}
}

// Latest 处理 GET /api/app/latest
// 返回最新版本元信息（含安装包地址、sha256、Ed25519 签名），供客户端检查更新
func (c *ReleaseController) Latest(w http.ResponseWriter, r *http.Request) {
	// 版本信息为公开只读数据，允许跨域：官网落地页可据此动态展示最新版与下载链接
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method != http.MethodOptions && r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if r.Method == http.MethodOptions {
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}

	release, err := c.svc.Latest()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "load release failed: " + err.Error()})
		return
	}
	if release == nil {
		writeJSON(w, http.StatusNotFound, Response{Code: 404, Msg: "no release published"})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: release})
}

// Download 处理 GET /download/<文件名>
// 安装包体积较大，直接交给 http.ServeFile（支持断点/分段）
func (c *ReleaseController) Download(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	path, err := c.svc.OpenPackage(filepath.Base(r.URL.Path))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	http.ServeFile(w, r, path)
}
