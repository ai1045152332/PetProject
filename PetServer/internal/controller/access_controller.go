package controller

import (
	"encoding/json"
	"net/http"

	"petserver/internal/model"
	"petserver/internal/service"
)

// AccessController 校验码接口控制器
type AccessController struct {
	svc *service.AccessService
}

// NewAccessController 创建校验码控制器
func NewAccessController(svc *service.AccessService) *AccessController {
	return &AccessController{svc: svc}
}

// Verify 处理 POST /api/access/verify
func (c *AccessController) Verify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}

	var req model.AccessVerifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}

	if req.Code == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: code"})
		return
	}
	if req.DeviceID == "" {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "missing field: deviceId"})
		return
	}

	valid, reason := c.svc.Verify(req.Code, req.DeviceID)
	writeJSON(w, http.StatusOK, Response{
		Code: 0,
		Msg:  "ok",
		Data: model.AccessVerifyResult{Valid: valid, Reason: reason},
	})
}
