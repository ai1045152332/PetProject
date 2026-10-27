// social_controller.go 好友与宠物消息接口控制器
// 统一 POST /api/social/<action>，action ∈ register / add / list / remove / send。
// 请求体走加密信封（含 deviceId 等敏感字段），与 access / pet-images 一致；curl 调试可发明文。
// 响应一律 HTTP 200，业务失败用信封 code≠0 + msg 文案回传（客户端据此提示）。
package controller

import (
	"encoding/json"
	"net/http"
	"strings"

	"petserver/internal/crypto"
	"petserver/internal/model"
	"petserver/internal/service"
)

// SocialController 好友/消息控制器
type SocialController struct {
	svc     *service.SocialService
	keyPair *crypto.KeyPair
}

// NewSocialController 创建好友/消息控制器
func NewSocialController(svc *service.SocialService, keyPair *crypto.KeyPair) *SocialController {
	return &SocialController{svc: svc, keyPair: keyPair}
}

// socialRequest 各 action 公用的请求载荷（按 action 取用其中字段）
type socialRequest struct {
	DeviceID string `json:"deviceId"`
	PetName  string `json:"petName"`
	Hostname string `json:"hostname"`
	PetNo    int64  `json:"petNo"`
	Text     string `json:"text"`
}

// Handle 处理 /api/social/<action>
func (c *SocialController) Handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	action := strings.TrimPrefix(r.URL.Path, "/api/social/")

	body, err := ReadPayload(r, c.keyPair)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid payload: " + err.Error()})
		return
	}
	var req socialRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, Response{Code: 400, Msg: "invalid json: " + err.Error()})
		return
	}

	switch action {
	case "register":
		petNo := c.svc.EnsureRegistered(req.DeviceID, req.Hostname, req.PetName)
		if petNo == 0 {
			writeJSON(w, http.StatusOK, Response{Code: 1, Msg: service.ErrSocialInvalidDevice.Error()})
			return
		}
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"petNo": petNo}})
	case "add":
		friends, err := c.svc.AddFriend(req.DeviceID, req.PetNo)
		c.writeFriends(w, friends, err)
	case "remove":
		friends, err := c.svc.RemoveFriend(req.DeviceID, req.PetNo)
		c.writeFriends(w, friends, err)
	case "list":
		friends, err := c.svc.ListFriends(req.DeviceID)
		c.writeFriends(w, friends, err)
	case "send":
		if err := c.svc.SendMessage(req.DeviceID, req.PetNo, req.Text); err != nil {
			writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok"})
	default:
		http.NotFound(w, r)
	}
}

// writeFriends 统一好友列表响应：err 非空回业务失败，否则回 friends
func (c *SocialController) writeFriends(w http.ResponseWriter, friends []model.FriendEntry, err error) {
	if err != nil {
		writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"friends": friends}})
}
