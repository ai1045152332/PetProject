// social_sqlite_test.go SQLite 好友仓库与旧 JSON 状态搬运的单测
package storage

import (
	"path/filepath"
	"testing"
	"time"

	"petserver/internal/model"
)

// legacySocialState 造一份旧版单 JSON 状态：两台设备、一条好友、一条待处理申请、
// 一条已下发未确认的消息、一条留痕
func legacySocialState(now time.Time) model.SocialState {
	return model.SocialState{
		Counter: 2,
		Registry: map[string]*model.PetRegistration{
			"dev-a": {DeviceID: "dev-a", PetNo: 100001, PetName: "毛豆", Hostname: "hostA", FirstSeenAt: now.Add(-time.Hour), LastSeenAt: now},
			"dev-b": {DeviceID: "dev-b", PetNo: 100002, PetName: "汤圆", Hostname: "hostB", FirstSeenAt: now.Add(-time.Hour), LastSeenAt: now},
		},
		Friends: map[string][]model.FriendEntry{
			"dev-a": {{PetNo: 100002, PetName: "汤圆", AddedAt: now.Add(-time.Minute)}},
		},
		Requests: map[string]*model.FriendRequest{
			"dev-b": {ID: "req-1", FromDevice: "dev-b", FromPetNo: 100002, FromName: "汤圆", ToPetNo: 100001, CreatedAt: now.Add(-time.Minute)},
		},
		Inbox: map[string][]model.PetMessage{
			"dev-b": {{ID: "msg-1", FromPetNo: 100001, FromName: "毛豆", Text: "在吗", SentAt: now.Add(-20 * time.Minute)}},
		},
		Delivered: map[string]map[string]model.DeliveredMessage{
			"dev-b": {"msg-1": {
				Message:     model.PetMessage{ID: "msg-1", FromPetNo: 100001, FromName: "毛豆", Text: "在吗", SentAt: now.Add(-20 * time.Minute)},
				DeliveredAt: now.Add(-time.Minute),
				Times:       2,
			}},
		},
		History: []model.PetConversationRecord{
			{Kind: model.ConversationKindMessage, FromPetNo: 100001, FromName: "毛豆", FromHost: "hostA",
				ToPetNo: 100002, ToName: "汤圆", ToHost: "hostB", ToDeviceID: "dev-b",
				IDs: []string{"msg-1"}, Text: "在吗", SentAt: now.Add(-20 * time.Minute)},
		},
	}
}

func openTempSQLite(t *testing.T) *SocialSQLite {
	t.Helper()
	repo, err := NewSocialSQLite(filepath.Join(t.TempDir(), "petserver.db"), DefaultFirstPetNo)
	if err != nil {
		t.Fatalf("打开 SQLite 失败: %v", err)
	}
	t.Cleanup(func() { _ = repo.Close() })
	return repo
}

func TestImportSocialStateKeepsPetNoAndUnreadMessages(t *testing.T) {
	now := time.Now()
	repo := openTempSQLite(t)

	hasDevices, err := repo.HasDevices()
	if err != nil {
		t.Fatalf("检查空库失败: %v", err)
	}
	if hasDevices {
		t.Fatalf("新建库不该已有设备")
	}
	stats, err := repo.ImportSocialState(legacySocialState(now))
	if err != nil {
		t.Fatalf("导入旧状态失败: %v", err)
	}
	if stats.Devices != 2 || stats.Friends != 1 || stats.Requests != 1 || stats.Messages != 1 || stats.History != 1 {
		t.Errorf("导入条数不符: %+v", stats)
	}

	// 老设备宠物号不变
	reg, err := repo.DeviceByPetNo(100001)
	if err != nil || reg == nil || reg.DeviceID != "dev-a" || reg.PetName != "毛豆" {
		t.Fatalf("宠物号 100001 应仍指向 dev-a，得到 %+v err=%v", reg, err)
	}
	// 水位被抬到「已发 2 个号」之后，新设备拿到 100003，不会与旧号重复
	if got, err := repo.Register("dev-c", "hostC", "新宠", now); err != nil || got != 100003 {
		t.Errorf("新设备应分配 100003，得到 %d err=%v", got, err)
	}

	// 好友与待处理申请按原语义可读
	if friends, err := repo.Friends("dev-a"); err != nil || len(friends) != 1 || friends[0].PetNo != 100002 {
		t.Errorf("好友列表搬运不符: %+v err=%v", friends, err)
	}
	reqs, err := repo.RequestsTo(100001)
	if err != nil || len(reqs) != 1 || reqs[0].ID != "req-1" || reqs[0].FromName != "汤圆" {
		t.Errorf("待处理申请搬运不符（发起方昵称也要带上，弹窗要显示）: %+v err=%v", reqs, err)
	}

	// 未确认已读的消息仍在收件箱：刚下发过 1 分钟不重投，过了重投间隔后到点重投
	query := PendingQuery{RedeliverAfter: 10 * time.Minute, MaxDeliverTimes: 3, TTL: 24 * time.Hour}
	if msgs, err := repo.PendingMessages("dev-b", now, query); err != nil || len(msgs) != 0 {
		t.Errorf("1 分钟前刚下发过，不该重投，得到 %+v err=%v", msgs, err)
	}
	msgs, err := repo.PendingMessages("dev-b", now.Add(11*time.Minute), query)
	if err != nil || len(msgs) != 1 || msgs[0].ID != "msg-1" {
		t.Fatalf("过了重投间隔应仍能下发 msg-1，得到 %+v err=%v", msgs, err)
	}
	history, err := repo.History(1000)
	if err != nil || len(history) != 1 || history[0].IDs[0] != "msg-1" {
		t.Fatalf("留痕及其关联 ID 应保留，得到 %+v err=%v", history, err)
	}

	// 幂等：再导一次不会翻倍，也不会把新分配的 dev-c 挤掉
	if stats, err := repo.ImportSocialState(legacySocialState(now)); err != nil || stats.Devices != 0 || stats.Messages != 0 {
		t.Errorf("重复导入应全部跳过，得到 %+v err=%v", stats, err)
	}
	if got, err := repo.Register("dev-c", "hostC", "新宠", now); err != nil || got != 100003 {
		t.Errorf("重复导入不应改变已有宠物号，得到 %d err=%v", got, err)
	}
}

func TestExportSocialStateRoundTrip(t *testing.T) {
	now := time.Now()
	source := legacySocialState(now)
	repo := openTempSQLite(t)
	if _, err := repo.ImportSocialState(source); err != nil {
		t.Fatalf("导入失败: %v", err)
	}

	back, err := repo.ExportSocialState()
	if err != nil {
		t.Fatalf("导出失败: %v", err)
	}
	if back.Counter != source.Counter {
		t.Errorf("宠物号水位应还原，期望 %d 得到 %d", source.Counter, back.Counter)
	}
	if len(back.Registry) != 2 || len(back.Friends["dev-a"]) != 1 || back.Requests["dev-b"] == nil {
		t.Errorf("设备/好友/申请未还原: %+v", back)
	}
	if len(back.Inbox["dev-b"]) != 1 || back.Delivered["dev-b"]["msg-1"].Times != 2 {
		t.Errorf("收件箱与下发次数未还原: inbox=%+v delivered=%+v", back.Inbox["dev-b"], back.Delivered["dev-b"])
	}
	if len(back.History) != 1 || back.History[0].SentAt.UnixMilli() != source.History[0].SentAt.UnixMilli() {
		t.Errorf("留痕未还原: %+v", back.History)
	}
	// 还原成 JSON 再读回来，宠物号与未读消息仍在
	store, err := NewSocialStore(filepath.Join(t.TempDir(), "social.json"))
	if err != nil {
		t.Fatalf("创建文件存储失败: %v", err)
	}
	if err := store.Save(back); err != nil {
		t.Fatalf("写回 JSON 失败: %v", err)
	}
	again, err := store.Load()
	if err != nil {
		t.Fatalf("读回 JSON 失败: %v", err)
	}
	if again.Counter != source.Counter || again.Inbox["dev-b"][0].ID != "msg-1" {
		t.Errorf("JSON 往返后数据不符: %+v", again)
	}
}
