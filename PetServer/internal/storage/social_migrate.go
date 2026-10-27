// social_migrate.go 旧版单 JSON 状态与 SQLite 之间的搬运
// 只在首次启用 SQLite 时用一次：把 data/social.json 里的宠物号、好友、待处理申请、
// 收件箱与对话留痕原样搬进库里，老设备的宠物号和未读消息都不会变。
// 导入是幂等的（全部 INSERT OR IGNORE + 水位只增不减），中途失败重启再跑一次即可。
package storage

import (
	"database/sql"
	"fmt"

	"petserver/internal/model"
)

// SocialImportStats 一次导入写进的条数（供启动日志与人工核对）
type SocialImportStats struct {
	Devices  int
	Friends  int
	Requests int
	Messages int
	History  int
}

// HasDevices 库里是否已有设备记录（首次导入前用来判断「是不是空库」）
func (s *SocialSQLite) HasDevices() (bool, error) {
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM devices LIMIT 1`).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// ImportSocialState 把旧 JSON 状态搬进 SQLite，返回各表写入条数。
// 已有同主键数据一律跳过，因此可以安全重复执行。
func (s *SocialSQLite) ImportSocialState(state model.SocialState) (SocialImportStats, error) {
	var stats SocialImportStats

	tx, err := s.db.Begin()
	if err != nil {
		return stats, err
	}
	defer func() { _ = tx.Rollback() }()

	// 设备与宠物号：号段水位取「旧状态算出来的下一个号」与「库里现有值」的较大者，
	// 避免导入把已分配过的号重新发出去
	for _, reg := range state.Registry {
		if reg == nil || reg.DeviceID == "" {
			continue
		}
		res, err := tx.Exec(`INSERT OR IGNORE INTO devices(device_id, pet_no, pet_name, hostname, first_seen_ms, last_seen_ms)
			VALUES(?,?,?,?,?,?)`,
			reg.DeviceID, reg.PetNo, reg.PetName, reg.Hostname, reg.FirstSeenAt.UnixMilli(), reg.LastSeenAt.UnixMilli())
		if err != nil {
			return stats, fmt.Errorf("导入设备失败: %w", err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Devices++
		}
	}
	if next := DefaultFirstPetNo + state.Counter; next > 0 {
		if _, err := tx.Exec(`UPDATE meta SET value=? WHERE key='next_pet_no' AND value<?`, next, next); err != nil {
			return stats, fmt.Errorf("抬升宠物号水位失败: %w", err)
		}
	}

	for deviceID, entries := range state.Friends {
		for _, f := range entries {
			res, err := tx.Exec(`INSERT OR IGNORE INTO friends(device_id, friend_no, friend_name, added_ms) VALUES(?,?,?,?)`,
				deviceID, f.PetNo, f.PetName, f.AddedAt.UnixMilli())
			if err != nil {
				return stats, fmt.Errorf("导入好友失败: %w", err)
			}
			if n, _ := res.RowsAffected(); n > 0 {
				stats.Friends++
			}
		}
	}

	for _, req := range state.Requests {
		if req == nil || req.FromDevice == "" {
			continue
		}
		res, err := tx.Exec(`INSERT OR IGNORE INTO requests(from_device, id, from_no, from_name, to_no, created_ms) VALUES(?,?,?,?,?,?)`,
			req.FromDevice, req.ID, req.FromPetNo, req.FromName, req.ToPetNo, req.CreatedAt.UnixMilli())
		if err != nil {
			return stats, fmt.Errorf("导入好友申请失败: %w", err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Requests++
		}
	}

	if err := importMessages(tx, state, &stats); err != nil {
		return stats, err
	}
	if err := importHistory(tx, state, &stats); err != nil {
		return stats, err
	}
	return stats, tx.Commit()
}

// importMessages 收件箱与「已下发待确认」合并成 messages 表的同一行
// 旧结构里两处各存一份（下发时收件箱保留副本），导入时以消息 ID 为主键自然合璧
func importMessages(tx *sql.Tx, state model.SocialState, stats *SocialImportStats) error {
	stmt, err := tx.Prepare(`INSERT OR IGNORE INTO
		messages(id, to_device, from_no, from_name, text, sent_ms, delivered_ms, deliver_times)
		VALUES(?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer func() { _ = stmt.Close() }()

	write := func(deviceID string, msg model.PetMessage, deliveredAt sql.NullInt64, times int) error {
		res, err := stmt.Exec(msg.ID, deviceID, msg.FromPetNo, msg.FromName, msg.Text,
			msg.SentAt.UnixMilli(), deliveredAt, times)
		if err != nil {
			return fmt.Errorf("导入消息失败: %w", err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			stats.Messages++
		}
		return nil
	}

	for deviceID, msgs := range state.Inbox {
		for _, msg := range msgs {
			var (
				at    sql.NullInt64
				times int
			)
			if d, ok := state.Delivered[deviceID][msg.ID]; ok {
				at, times = sql.NullInt64{Int64: d.DeliveredAt.UnixMilli(), Valid: true}, d.Times
			}
			if err := write(deviceID, msg, at, times); err != nil {
				return err
			}
		}
	}
	// 兜底：只存在于下发名单、收件箱已被裁剪掉的消息（未读但超龄的会靠 TTL 自然沉默）
	for deviceID, delivered := range state.Delivered {
		inInbox := make(map[string]struct{}, len(state.Inbox[deviceID]))
		for _, msg := range state.Inbox[deviceID] {
			inInbox[msg.ID] = struct{}{}
		}
		for id, d := range delivered {
			if _, ok := inInbox[id]; ok {
				continue
			}
			at := sql.NullInt64{Int64: d.DeliveredAt.UnixMilli(), Valid: true}
			if err := write(deviceID, d.Message, at, d.Times); err != nil {
				return err
			}
		}
	}
	return nil
}

// importHistory 按旧数组顺序（旧 → 新）追加留痕，seq 自增正好保持这个顺序
func importHistory(tx *sql.Tx, state model.SocialState, stats *SocialImportStats) error {
	for _, rec := range state.History {
		res, err := tx.Exec(`INSERT INTO history(kind, from_no, from_name, from_host, to_no, to_name, to_host,
			to_device, text, sent_ms, delivered_ms, read_ms, handled_ms, status)
			VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			orDefault(rec.Kind, model.ConversationKindMessage), rec.FromPetNo, rec.FromName, rec.FromHost,
			rec.ToPetNo, rec.ToName, rec.ToHost, rec.ToDeviceID, rec.Text, rec.SentAt.UnixMilli(),
			nullMillis(rec.DeliveredAt), nullMillis(rec.ReadAt), nullMillis(rec.HandledAt), rec.Status)
		if err != nil {
			return fmt.Errorf("导入对话留痕失败: %w", err)
		}
		seq, err := res.LastInsertId()
		if err != nil {
			return err
		}
		for _, id := range rec.IDs {
			if id == "" {
				continue
			}
			if _, err := tx.Exec(`INSERT OR IGNORE INTO history_ids(seq, ref_id) VALUES(?,?)`, seq, id); err != nil {
				return fmt.Errorf("导入留痕关联 ID 失败: %w", err)
			}
		}
		stats.History++
	}
	return nil
}

// ExportSocialState 把 SQLite 里的好友与消息状态还原成旧 JSON 结构
// 用于「回滚到文件存储」前的数据兜底，以及排查时直接看一份完整快照。
func (s *SocialSQLite) ExportSocialState() (model.SocialState, error) {
	state := newEmptySocialState()

	rows, err := s.db.Query(`SELECT device_id, pet_no, pet_name, hostname, first_seen_ms, last_seen_ms
		FROM devices ORDER BY pet_no`)
	if err != nil {
		return state, err
	}
	defer func() { _ = rows.Close() }()

	var maxPetNo int64
	for rows.Next() {
		var (
			reg         model.PetRegistration
			first, last int64
		)
		if err := rows.Scan(&reg.DeviceID, &reg.PetNo, &reg.PetName, &reg.Hostname, &first, &last); err != nil {
			return state, err
		}
		reg.FirstSeenAt = millis(first)
		reg.LastSeenAt = millis(last)
		entry := reg
		state.Registry[reg.DeviceID] = &entry
		if reg.PetNo > maxPetNo {
			maxPetNo = reg.PetNo
		}
	}
	if err := rows.Err(); err != nil {
		return state, err
	}
	// 旧结构用 Counter 表达「已发放了几个号」，回滚后继续按同一水位发号
	if maxPetNo > 0 {
		state.Counter = maxPetNo - DefaultFirstPetNo + 1
	}

	friends, err := s.db.Query(`SELECT device_id, friend_no, friend_name, added_ms FROM friends ORDER BY added_ms, friend_no`)
	if err != nil {
		return state, err
	}
	defer func() { _ = friends.Close() }()
	for friends.Next() {
		var (
			deviceID string
			f        model.FriendEntry
			added    int64
		)
		if err := friends.Scan(&deviceID, &f.PetNo, &f.PetName, &added); err != nil {
			return state, err
		}
		f.AddedAt = millis(added)
		state.Friends[deviceID] = append(state.Friends[deviceID], f)
	}
	if err := friends.Err(); err != nil {
		return state, err
	}

	reqs, err := s.db.Query(`SELECT from_device, id, from_no, from_name, to_no, created_ms FROM requests ORDER BY created_ms`)
	if err != nil {
		return state, err
	}
	defer func() { _ = reqs.Close() }()
	for reqs.Next() {
		var (
			req     model.FriendRequest
			created int64
		)
		if err := reqs.Scan(&req.FromDevice, &req.ID, &req.FromPetNo, &req.FromName, &req.ToPetNo, &created); err != nil {
			return state, err
		}
		req.CreatedAt = millis(created)
		entry := req
		state.Requests[req.FromDevice] = &entry
	}
	if err := reqs.Err(); err != nil {
		return state, err
	}

	msgs, err := s.db.Query(`SELECT id, to_device, from_no, from_name, text, sent_ms, delivered_ms, deliver_times
		FROM messages ORDER BY sent_ms, rowid`)
	if err != nil {
		return state, err
	}
	defer func() { _ = msgs.Close() }()
	for msgs.Next() {
		var (
			msg       model.PetMessage
			deviceID  string
			sent      int64
			delivered sql.NullInt64
			times     int
		)
		if err := msgs.Scan(&msg.ID, &deviceID, &msg.FromPetNo, &msg.FromName, &msg.Text, &sent, &delivered, &times); err != nil {
			return state, err
		}
		msg.SentAt = millis(sent)
		state.Inbox[deviceID] = append(state.Inbox[deviceID], msg)
		if delivered.Valid {
			if state.Delivered[deviceID] == nil {
				state.Delivered[deviceID] = map[string]model.DeliveredMessage{}
			}
			state.Delivered[deviceID][msg.ID] = model.DeliveredMessage{
				Message:     msg,
				DeliveredAt: millis(delivered.Int64),
				Times:       times,
			}
		}
	}
	if err := msgs.Err(); err != nil {
		return state, err
	}

	history, err := s.History(0)
	if err != nil {
		return state, err
	}
	state.History = history
	return state, nil
}
