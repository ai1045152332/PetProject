// social_service_test.go 好友与宠物消息业务单测
package service

import (
	"errors"
	"path/filepath"
	"testing"

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

func TestAddFriendValidation(t *testing.T) {
	svc := newTestSocialService(t)
	owner := svc.EnsureRegistered("device-owner", "h", "主人")
	target := svc.EnsureRegistered("device-target", "h", "朋友")
	_ = owner

	if _, err := svc.AddFriend("device-owner", target); err != nil {
		t.Fatalf("添加合法好友应成功: %v", err)
	}
	// 幂等：重复添加不报错、不产生重复条目
	friends, err := svc.AddFriend("device-owner", target)
	if err != nil {
		t.Fatalf("重复添加应幂等: %v", err)
	}
	if len(friends) != 1 {
		t.Errorf("好友应去重，得到 %d 条", len(friends))
	}
	if _, err := svc.AddFriend("device-owner", target); err == nil {
		// 再次确认自己→自己
	}
	// 加自己
	if _, err := svc.AddFriend("device-target", target); !errors.Is(err, ErrSocialAddSelf) {
		t.Errorf("添加自己应报 ErrSocialAddSelf，得到 %v", err)
	}
	// 加不存在的宠物号
	if _, err := svc.AddFriend("device-owner", 999999); !errors.Is(err, ErrSocialPetNotFound) {
		t.Errorf("添加不存在宠物号应报 ErrSocialPetNotFound，得到 %v", err)
	}
}

func TestSendMessageRequiresFriendshipAndDrainsOnTake(t *testing.T) {
	svc := newTestSocialService(t)
	svc.EnsureRegistered("device-a", "h", "A")
	svc.EnsureRegistered("device-b", "h", "B")
	bPetNo := svc.EnsureRegistered("device-b", "h", "B")

	// 未加好友：发消息应被拒
	if err := svc.SendMessage("device-a", bPetNo, "你好"); !errors.Is(err, ErrSocialNotFriend) {
		t.Fatalf("未加好友发消息应报 ErrSocialNotFriend，得到 %v", err)
	}
	if _, err := svc.AddFriend("device-a", bPetNo); err != nil {
		t.Fatalf("加好友失败: %v", err)
	}
	// 空消息
	if err := svc.SendMessage("device-a", bPetNo, "   "); !errors.Is(err, ErrSocialEmptyMessage) {
		t.Errorf("空消息应报 ErrSocialEmptyMessage，得到 %v", err)
	}
	// 加好友后可发送
	if err := svc.SendMessage("device-a", bPetNo, "在吗"); err != nil {
		t.Fatalf("发消息应成功: %v", err)
	}

	// B 拉取：应收到 1 条，且取后即清
	msgs := svc.TakePendingMessages("device-b")
	if len(msgs) != 1 {
		t.Fatalf("期望取到 1 条消息，得到 %d", len(msgs))
	}
	if msgs[0].Text != "在吗" || msgs[0].FromName != "A" {
		t.Errorf("消息内容不符: %+v", msgs[0])
	}
	if again := svc.TakePendingMessages("device-b"); again != nil {
		t.Errorf("再次拉取应为空，得到 %+v", again)
	}

	// 对话留痕：取走后后台仍能看到这条往来消息
	convs := svc.Conversations()
	if len(convs) != 1 {
		t.Fatalf("期望留痕 1 条，得到 %d", len(convs))
	}
	if convs[0].Text != "在吗" || convs[0].FromName != "A" || convs[0].ToName != "B" {
		t.Errorf("留痕内容不符: %+v", convs[0])
	}
	// 清空后不再展示
	if err := svc.ClearConversations(); err != nil {
		t.Fatalf("清空留痕应成功: %v", err)
	}
	if left := svc.Conversations(); len(left) != 0 {
		t.Errorf("清空后应无留痕，得到 %d 条", len(left))
	}
}
