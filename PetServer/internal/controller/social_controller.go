// social_controller.go 好友与宠物消息接口控制器
// 统一 POST /api/social/<action>，action ∈ register / add / requests / accept / reject /
// list / remove / send / read / history。加好友需对方同意（add 只发申请，accept 后才双向互为好友）；
// read 由客户端看完消息关卡时上报，服务端据此标记已读；history 回看与某好友的最近聊天记录。
// 请求体走加密信封（含 deviceId 等敏感字段），与 access / pet-images 一致；curl 调试可发明文。
// 响应一律 HTTP 200，业务失败用信封 code≠0 + msg 文案回传（客户端据此提示）。
package controller

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

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
	DeviceID string   `json:"deviceId"`
	PetName  string   `json:"petName"`
	Hostname string   `json:"hostname"`
	PetNo    int64    `json:"petNo"`
	Text     string   `json:"text"`
	IDs      []string `json:"ids"` // read：本次确认已读的消息 ID
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
		friends, status, err := c.svc.RequestFriend(req.DeviceID, req.PetNo)
		if err != nil {
			writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
			"friends": friends,
			"status":  status, // pending：等对方同意；mutual：已互为好友
		}})
	case "requests":
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
			"requests": c.pendingRequestsOf(req.DeviceID),
		}})
	case "accept":
		friends, err := c.svc.AcceptFriendRequest(req.DeviceID, req.PetNo)
		c.writeFriends(w, friends, err)
	case "reject":
		friends, err := c.svc.RejectFriendRequest(req.DeviceID, req.PetNo)
		c.writeFriends(w, friends, err)
	case "read":
		hit, err := c.svc.MarkMessagesRead(req.DeviceID, req.IDs)
		if err != nil {
			writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"marked": hit}})
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
	case "history":
		records, err := c.svc.ConversationBetween(req.DeviceID, req.PetNo)
		if err != nil {
			writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
			"messages": c.historyItems(records),
		}})
	default:
		http.NotFound(w, r)
	}
}

// socialHistoryItem 聊天窗回看用的一条消息：时间统一给 UnixMilli，
// 客户端免去解析 RFC3339 时区；留痕原始结构留给管理后台，两边互不影响
type socialHistoryItem struct {
	ID        string `json:"id"`
	FromPetNo int64  `json:"fromPetNo"`
	FromName  string `json:"fromName"`
	Text      string `json:"text"`
	SentMs    int64  `json:"sentMs"`
	ReadMs    int64  `json:"readMs"` // 0 = 对方尚未确认已读
}

// historyItems 把消息留痕摊平成聊天窗一行行（旧 → 新保持不变）
func (c *SocialController) historyItems(records []model.PetConversationRecord) []socialHistoryItem {
	out := make([]socialHistoryItem, 0, len(records))
	for _, rec := range records {
		id := ""
		if len(rec.IDs) > 0 {
			id = rec.IDs[0]
		}
		out = append(out, socialHistoryItem{
			ID: id, FromPetNo: rec.FromPetNo, FromName: rec.FromName, Text: rec.Text,
			SentMs: rec.SentAt.UnixMilli(), ReadMs: millisOrNil(rec.ReadAt),
		})
	}
	return out
}

// millisOrNil 零值时间回 0（表示「尚未已读」，避免 UnixMilli 的负数极值污染展示）
func millisOrNil(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

// pendingRequestsOf 返回发给该设备的待处理好友申请（旧 → 新），nil 归一为空切片便于 JSON 输出
func (c *SocialController) pendingRequestsOf(deviceID string) []model.FriendRequest {
	reqs := c.svc.PendingRequests(deviceID)
	if reqs == nil {
		return []model.FriendRequest{}
	}
	return reqs
}

// writeFriends 统一好友列表响应：err 非空回业务失败，否则回 friends
func (c *SocialController) writeFriends(w http.ResponseWriter, friends []model.FriendEntry, err error) {
	if err != nil {
		writeJSON(w, http.StatusOK, Response{Code: 1, Msg: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{"friends": friends}})
}
