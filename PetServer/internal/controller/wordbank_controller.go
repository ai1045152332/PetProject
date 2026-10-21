// wordbank_controller.go
// 背单词词库下发接口（免登录，词库内容不敏感）
package controller

import (
	"net/http"

	"petserver/internal/service"
)

// WordBankController 词库控制器
type WordBankController struct {
	bankSvc *service.WordBankService
}

// NewWordBankController 创建词库控制器
func NewWordBankController(bankSvc *service.WordBankService) *WordBankController {
	return &WordBankController{bankSvc: bankSvc}
}

// List 处理 GET /api/wordbank/list —— 返回词库名与字节数（客户端据此判断是否需重新下载）
func (c *WordBankController) List(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	entries, err := c.bankSvc.List()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: err.Error()})
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"banks": entries}})
}

// Get 处理 GET /api/wordbank/get?name=cet4 —— 直接返回词库 JSON 原文
func (c *WordBankController) Get(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	name := r.URL.Query().Get("name")
	data, err := c.bankSvc.Open(name)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: err.Error()})
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(data)
}
