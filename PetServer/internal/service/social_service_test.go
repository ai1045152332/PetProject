// social_service_test.go 好友与宠物消息业务单测
package service

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

func newTestSocialService(t *testing.T) *SocialService {
	t.Helper()
	store, err := storage.NewSocialStore(filepath.Join(t.TempDir(), "social.json"))
	if err != nil {
		t.Fatalf("创建存储失败: %v", err)
	}
	return NewSocialService(store)
}

func TestEnsureRegisteredAssignsStableIncrementalPetNo(t *testing.T) {
	svc := newTestSocialService(t)

	a := svc.EnsureRegistered("device-a", "hostA", "毛豆")
	b := svc.EnsureRegistered("device-b", "hostB", "汤圆")
	if a == 0 || b == 0 {
		t.Fatalf("应分配非零宠物号，得到 a=%d b=%d", a, b)
	}
	if b != a+1 {
		t.Errorf("宠物号应自增，期望 %d 得到 %d", a+1, b)
	}
	// 重复注册保持同一宠物号
	if again := svc.EnsureRegistered("device-a", "hostA", "毛豆"); again != a {
		t.Errorf("重复注册宠物号应稳定，期望 %d 得到 %d", a, again)
	}
	// 无效设备返回 0
	if got := svc.EnsureRegistered("unknown-device", "", ""); got != 0 {
		t.Errorf("无效设备应返回 0，得到 %d", got)
	}
}

func TestRequestFriendWaitsForConsent(t *testing.T) {
	svc := newTestSocialService(t)
	owner := svc.EnsureRegistered("device-owner", "h", "主人")
	target := svc.EnsureRegistered("device-target", "h", "朋友")

	// 发申请：双方都还没成为好友，只留下待处理申请
	friends, status, err := svc.RequestFriend("device-owner", target)
	if err != nil {
		t.Fatalf("发起好友申请应成功: %v", err)
	}
	if status != FriendRequestPending {
		t.Errorf("首次申请应为 pending，得到 %s", status)
	}
	if len(friends) != 0 {
		t.Errorf("对方同意前自己不该有好友，得到 %d 条", len(friends))
	}
	if got, err := svc.ListFriends("device-target"); err != nil || len(got) != 0 {
		t.Errorf("对方同意前 TA 也不该有好友，得到 %+v err=%v", got, err)
	}
	// 幂等：重复申请不产生第二条待处理申请
	if _, status, err := svc.RequestFriend("device-owner", target); err != nil || status != FriendRequestPending {
		t.Fatalf("重复申请应幂等返回 pending，得到 status=%s err=%v", status, err)
	}
	if reqs := svc.PendingRequests("device-target"); len(reqs) != 1 {
		t.Fatalf("待处理申请应只有 1 条，得到 %d 条", len(reqs))
	}

	// 加自己 / 加不存在的宠物号
	if _, _, err := svc.RequestFriend("device-target", target); !errors.Is(err, ErrSocialAddSelf) {
		t.Errorf("添加自己应报 ErrSocialAddSelf，得到 %v", err)
	}
	if _, _, err := svc.RequestFriend("device-owner", 999999); !errors.Is(err, ErrSocialPetNotFound) {
		t.Errorf("添加不存在宠物号应报 ErrSocialPetNotFound，得到 %v", err)
	}
	// 未处理时拒绝后再同意应报无申请
	if _, err := svc.RejectFriendRequest("device-target", owner); err != nil {
		t.Fatalf("拒绝申请应成功: %v", err)
	}
	if _, err := svc.AcceptFriendRequest("device-target", owner); !errors.Is(err, ErrSocialNoRequest) {
		t.Errorf("已拒绝的申请再同意应报 ErrSocialNoRequest，得到 %v", err)
	}
}

func TestAcceptFriendRequestMakesBothSidesFriends(t *testing.T) {
	svc := newTestSocialService(t)
	owner := svc.EnsureRegistered("device-owner", "hA", "主人")
	target := svc.EnsureRegistered("device-target", "hB", "朋友")

	if _, _, err := svc.RequestFriend("device-owner", target); err != nil {
		t.Fatalf("发起申请失败: %v", err)
	}
	friends, err := svc.AcceptFriendRequest("device-target", owner)
	if err != nil {
		t.Fatalf("同意申请应成功: %v", err)
	}
	if len(friends) != 1 || friends[0].PetNo != owner || friends[0].PetName != "主人" {
		t.Fatalf("同意方应把发起方列为好友，得到 %+v", friends)
	}
	// 双向互加：发起方也拿到对方
	mine, err := svc.ListFriends("device-owner")
	if err != nil || len(mine) != 1 || mine[0].PetNo != target {
		t.Errorf("发起方应互为好友，得到 %+v err=%v", mine, err)
	}
	// 同意后不再有，重复同意报无申请
	if reqs := svc.PendingRequests("device-target"); reqs != nil {
		t.Errorf("处理后不应有待处理申请，得到 %+v", reqs)
	}
	if _, err := svc.AcceptFriendRequest("device-target", owner); !errors.Is(err, ErrSocialNoRequest) {
		t.Errorf("重复同意应报 ErrSocialNoRequest，得到 %v", err)
	}

	// 留痕：申请记录状态为 accepted，同意方在双方列表都能看到彼此
	var found bool
	for _, rec := range svc.Conversations() {
		if rec.Kind == model.ConversationKindRequest {
			found = true
			if rec.Status != "accepted" || rec.HandledAt.IsZero() {
				t.Errorf("申请留痕状态不符: %+v", rec)
			}
		}
	}
	if !found {
		t.Errorf("应留下好友申请留痕")
	}

	// 删好友：双向解除
	if _, err := svc.RemoveFriend("device-owner", target); err != nil {
		t.Fatalf("删好友应成功: %v", err)
	}
	for _, deviceID := range []string{"device-owner", "device-target"} {
		if got, err := svc.ListFriends(deviceID); err != nil || len(got) != 0 {
			t.Errorf("删除后 %s 应为空好友列表，得到 %+v err=%v", deviceID, got, err)
		}
	}
}

func TestMutualRequestsBecomeFriendsDirectly(t *testing.T) {
	svc := newTestSocialService(t)
	a := svc.EnsureRegistered("device-a", "hA", "A")
	b := svc.EnsureRegistered("device-b", "hB", "B")

	if _, _, err := svc.RequestFriend("device-a", b); err != nil {
		t.Fatalf("A 申请失败: %v", err)
	}
	// B 也申请 A：视为互相同意，直接双向成为好友
	friends, status, err := svc.RequestFriend("device-b", a)
	if err != nil {
		t.Fatalf("B 申请应成功: %v", err)
	}
	if status != FriendRequestMutual {
		t.Errorf("双向申请应回 mutual，得到 %s", status)
	}
	if len(friends) != 1 || friends[0].PetNo != a {
		t.Errorf("B 的好友列表应含 A，得到 %+v", friends)
	}
	if mine, _ := svc.ListFriends("device-a"); len(mine) != 1 || mine[0].PetNo != b {
		t.Errorf("A 的好友列表应含 B，得到 %+v", mine)
	}
	if reqs := svc.PendingRequests("device-a"); reqs != nil {
		t.Errorf("互加后不应残留待处理申请，得到 %+v", reqs)
	}
}

func TestMessageDeliveryRequiresConsentAndTracksRead(t *testing.T) {
	svc := newTestSocialService(t)
	svc.EnsureRegistered("device-a", "h", "A")
	bPetNo := svc.EnsureRegistered("device-b", "h", "B")

	// 只是单方申请、对方未同意：不算好友，发消息应被拒
	if _, _, err := svc.RequestFriend("device-a", bPetNo); err != nil {
		t.Fatalf("发起申请失败: %v", err)
	}
	if err := svc.SendMessage("device-a", bPetNo, "你好"); !errors.Is(err, ErrSocialNotFriend) {
		t.Fatalf("未成为好友发消息应报 ErrSocialNotFriend，得到 %v", err)
	}
	// 空消息（此时已互为好友，才会走到内容校验）
	if _, err := svc.AcceptFriendRequest("device-b", svc.PetNoFor("device-a")); err != nil {
		t.Fatalf("B 同意申请失败: %v", err)
	}
	if err := svc.SendMessage("device-a", bPetNo, "   "); !errors.Is(err, ErrSocialEmptyMessage) {
		t.Errorf("空消息应报 ErrSocialEmptyMessage，得到 %v", err)
	}

	// 互为好友后可发送
	if err := svc.SendMessage("device-a", bPetNo, "在吗"); err != nil {
		t.Fatalf("发消息应成功: %v", err)
	}

	// B 心跳取消息：首次下发后登记，未确认已读前收件箱不清空
	msgs := svc.PeekPendingMessages("device-b")
	if len(msgs) != 1 {
		t.Fatalf("期望取到 1 条消息，得到 %d", len(msgs))
	}
	if msgs[0].Text != "在吗" || msgs[0].FromName != "A" {
		t.Errorf("消息内容不符: %+v", msgs[0])
	}
	svc.DeliverMessages("device-b", msgs)
	if again := svc.PeekPendingMessages("device-b"); again != nil {
		t.Errorf("刚下发过且未确认，短时内不该重复下发，得到 %+v", again)
	}

	// 未确认已读前：后台看到的是「已下发未读」
	before := svc.Conversations()
	if len(before) == 0 || before[len(before)-1].ReadAt.IsZero() == false {
		t.Fatalf("未确认前留痕不该有已读时间: %+v", before)
	}

	// B 看完关卡确认已读：留痕盖上已读时间，消息不再下发
	hit, err := svc.MarkMessagesRead("device-b", []string{msgs[0].ID})
	if err != nil {
		t.Fatalf("确认已读应成功: %v", err)
	}
	if hit != 1 {
		t.Errorf("应命中 1 条留痕，得到 %d", hit)
	}
	if again := svc.PeekPendingMessages("device-b"); again != nil {
		t.Errorf("已读后不该再下发，得到 %+v", again)
	}
	after := svc.Conversations()
	last := after[len(after)-1]
	if last.Text != "在吗" || last.Kind != model.ConversationKindMessage {
		t.Errorf("留痕内容不符: %+v", last)
	}
	if last.ReadAt.IsZero() || last.DeliveredAt.IsZero() {
		t.Errorf("留痕应有下发与已读时间: %+v", last)
	}
	if !last.ReadAt.After(last.DeliveredAt.Add(-time.Second)) {
		t.Errorf("已读时间不应早于下发时间: %+v", last)
	}
	// 重复确认不再命中
	if hit, err := svc.MarkMessagesRead("device-b", []string{msgs[0].ID}); err != nil || hit != 0 {
		t.Errorf("重复确认应命中 0 条，得到 hit=%d err=%v", hit, err)
	}

	// 清空后不再展示
	if err := svc.ClearConversations(); err != nil {
		t.Fatalf("清空留痕应成功: %v", err)
	}
	if left := svc.Conversations(); len(left) != 0 {
		t.Errorf("清空后应无留痕，得到 %d 条", len(left))
	}
}
