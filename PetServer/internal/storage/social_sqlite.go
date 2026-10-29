// social_sqlite.go 好友与宠物消息的 SQLite 仓库实现
// 表设计围绕「一次业务动作只碰涉及的行」：申请一行、消息一行、留痕一行，
// 已读/下发状态是消息与留痕行上的列，不再需要整份状态读写。
// 驱动用 ncruces/go-sqlite3（纯 Go + 内嵌 wasm，无 CGO），保持 GOOS=linux 交叉编译发布流程不变。
package storage

import (
	"database/sql"
	"fmt"
	"strings"
	"sync"
	"time"

	_ "github.com/ncruces/go-sqlite3/driver"

	"petserver/internal/model"
)

// DefaultFirstPetNo 宠物号起始水位（自增分配，贴近 QQ 早期号段的观感、便于口头传播）。
// 号段规则归存储层管：水位存在 meta 表，换实现也必须沿用同一水位，避免出现重号。
const DefaultFirstPetNo = int64(100001)

// SocialSQLite 好友与消息的 SQLite 仓库
type SocialSQLite struct {
	db *sql.DB
	// 连接级串行锁：SQLite 是单写者库，读改写（如分配宠物号）必须整体串行，
	// 与业务层 SocialService 的锁相互叠加，保证同一动作不会交叉。
	mu sync.Mutex
}

var _ SocialRepo = (*SocialSQLite)(nil)

// socialSchema 建表语句（幂等，进程启动时执行）
// 时间统一存 UnixMilli 整数：可比较、可排序，零值用 NULL 表达「尚未发生」
const socialSchema = `
CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
	device_id     TEXT PRIMARY KEY,
	pet_no        INTEGER NOT NULL UNIQUE,
	pet_name      TEXT NOT NULL DEFAULT '',
	hostname      TEXT NOT NULL DEFAULT '',
	first_seen_ms INTEGER NOT NULL,
	last_seen_ms  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS friends (
	device_id   TEXT NOT NULL,
	friend_no   INTEGER NOT NULL,
	friend_name TEXT NOT NULL DEFAULT '',
	added_ms    INTEGER NOT NULL,
	PRIMARY KEY (device_id, friend_no)
);
-- 待处理好友申请：主键为「发起方→接收方」一对一条，同一发起方给多人发申请互不覆盖；
-- 同一方向重复申请就地覆盖（换新申请 ID，接收端按新 ID 重新弹卡）
CREATE TABLE IF NOT EXISTS requests (
	from_device TEXT NOT NULL,
	to_no       INTEGER NOT NULL,
	id          TEXT NOT NULL UNIQUE,
	from_no     INTEGER NOT NULL,
	from_name   TEXT NOT NULL DEFAULT '',
	created_ms  INTEGER NOT NULL,
	PRIMARY KEY (from_device, to_no)
);
CREATE INDEX IF NOT EXISTS idx_requests_to ON requests(to_no, created_ms);
-- 收件箱与「已下发待确认」合并为一张表：未读且未下发时 delivered_ms 为 NULL，
-- 确认后整行删除，天然不会出现两处状态不同步
CREATE TABLE IF NOT EXISTS messages (
	id            TEXT PRIMARY KEY,
	to_device     TEXT NOT NULL,
	from_no       INTEGER NOT NULL,
	from_name     TEXT NOT NULL DEFAULT '',
	text          TEXT NOT NULL,
	sent_ms       INTEGER NOT NULL,
	delivered_ms  INTEGER,
	deliver_times INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_device, sent_ms);
-- 对话留痕：供管理后台展示好友往来与已读情况，seq 自增保证「旧 → 新」稳定顺序
CREATE TABLE IF NOT EXISTS history (
	seq          INTEGER PRIMARY KEY AUTOINCREMENT,
	kind         TEXT NOT NULL DEFAULT 'message',
	from_no      INTEGER NOT NULL,
	from_name    TEXT NOT NULL DEFAULT '',
	from_host    TEXT NOT NULL DEFAULT '',
	to_no        INTEGER NOT NULL,
	to_name      TEXT NOT NULL DEFAULT '',
	to_host      TEXT NOT NULL DEFAULT '',
	to_device    TEXT NOT NULL DEFAULT '',
	text         TEXT NOT NULL DEFAULT '',
	sent_ms      INTEGER NOT NULL,
	delivered_ms INTEGER,
	read_ms      INTEGER,
	handled_ms   INTEGER,
	status       TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_history_sent ON history(sent_ms);
-- 留痕关联的消息/申请 ID（一条留痕可关联多个 ID，便于按 ID 回查状态）
CREATE TABLE IF NOT EXISTS history_ids (
	seq    INTEGER NOT NULL,
	ref_id TEXT NOT NULL,
	PRIMARY KEY (seq, ref_id)
);
CREATE INDEX IF NOT EXISTS idx_history_ids_ref ON history_ids(ref_id);
`

// NewSocialSQLite 打开（必要时创建）SQLite 库并完成建表。
// path 传 ":memory:" 得到仅本连接可见的内存库（测试用）。
// firstPetNo 是宠物号起始水位，仅首次分配时使用。
func NewSocialSQLite(path string, firstPetNo int64) (*SocialSQLite, error) {
	dsn := "file:" + path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(1)"
	if path == ":memory:" {
		// 内存库无 WAL 的必要，且不能落盘
		dsn = "file::memory:?_pragma=busy_timeout(5000)"
	}
	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开 SQLite 失败: %w", err)
	}
	// 只留一条连接：内存库跨连接即失效，文件库也免去多连接抢写锁
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	s := &SocialSQLite{db: db}
	if _, err := db.Exec(socialSchema); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("初始化好友消息表失败: %w", err)
	}
	if err := s.rebuildRequestsTableIfLegacy(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("升级好友申请表失败: %w", err)
	}
	// 首次使用时播种宠物号水位
	var seed int64
	err = db.QueryRow(`SELECT value FROM meta WHERE key='next_pet_no'`).Scan(&seed)
	if err == sql.ErrNoRows {
		if _, err := db.Exec(`INSERT INTO meta(key, value) VALUES('next_pet_no', ?)`, firstPetNo); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("初始化宠物号水位失败: %w", err)
		}
	} else if err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("读取宠物号水位失败: %w", err)
	}
	return s, nil
}

// rebuildRequestsTableIfLegacy 把旧版「发起方为主键」的申请表重建成「发起方→接收方」复合主键。
// 旧主键下同一发起方给多人发申请会互相覆盖（后来者顶掉前一条，先被加的一方永远收不到），
// 检测到旧表结构就整表替换；旧表每发起方至多一条，重建后天然满足新主键，不会冲突。
func (s *SocialSQLite) rebuildRequestsTableIfLegacy() error {
	var oldSQL string
	err := s.db.QueryRow(`SELECT sql FROM sqlite_master WHERE type='table' AND name='requests'`).Scan(&oldSQL)
	if err == sql.ErrNoRows {
		return nil // 建表语句会新建，无需处理
	}
	if err != nil {
		return err
	}
	if !strings.Contains(oldSQL, "from_device TEXT PRIMARY KEY") {
		return nil // 已是新结构
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`CREATE TABLE requests_new (
		from_device TEXT NOT NULL,
		to_no       INTEGER NOT NULL,
		id          TEXT NOT NULL UNIQUE,
		from_no     INTEGER NOT NULL,
		from_name   TEXT NOT NULL DEFAULT '',
		created_ms  INTEGER NOT NULL,
		PRIMARY KEY (from_device, to_no)
	)`); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO requests_new(from_device, to_no, id, from_no, from_name, created_ms)
		SELECT from_device, to_no, id, from_no, from_name, created_ms FROM requests`); err != nil {
		return err
	}
	if _, err := tx.Exec(`DROP TABLE requests`); err != nil {
		return err
	}
	if _, err := tx.Exec(`ALTER TABLE requests_new RENAME TO requests`); err != nil {
		return err
	}
	if _, err := tx.Exec(`CREATE INDEX IF NOT EXISTS idx_requests_to ON requests(to_no, created_ms)`); err != nil {
		return err
	}
	return tx.Commit()
}

// DB 暴露底层句柄，仅供迁移脚本与运维查询使用（业务代码不要直接动表）
func (s *SocialSQLite) DB() *sql.DB { return s.db }

// Close 关闭底层连接
func (s *SocialSQLite) Close() error { return s.db.Close() }

// ── 设备注册 ──────────────────────────────────────────────

// Register 确保设备已注册，返回其宠物号；空 petName/hostname 不覆盖已有值
func (s *SocialSQLite) Register(deviceID, hostname, petName string, now time.Time) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	var petNo int64
	err = tx.QueryRow(`SELECT pet_no FROM devices WHERE device_id=?`, deviceID).Scan(&petNo)
	switch {
	case err == sql.ErrNoRows:
		if err := tx.QueryRow(`SELECT value FROM meta WHERE key='next_pet_no'`).Scan(&petNo); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(`UPDATE meta SET value=value+1 WHERE key='next_pet_no'`); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(`INSERT INTO devices(device_id, pet_no, pet_name, hostname, first_seen_ms, last_seen_ms)
			VALUES(?,?,?,?,?,?)`, deviceID, petNo, petName, hostname, now.UnixMilli(), now.UnixMilli()); err != nil {
			return 0, err
		}
	case err != nil:
		return 0, err
	default:
		if _, err := tx.Exec(`UPDATE devices
			SET pet_name=COALESCE(NULLIF(?, ''), pet_name),
			    hostname=COALESCE(NULLIF(?, ''), hostname),
			    last_seen_ms=?
			WHERE device_id=?`, petName, hostname, now.UnixMilli(), deviceID); err != nil {
			return 0, err
		}
	}
	return petNo, tx.Commit()
}

func (s *SocialSQLite) DeviceByID(deviceID string) (*model.PetRegistration, error) {
	return s.queryDevice(`WHERE device_id=?`, deviceID)
}

func (s *SocialSQLite) DeviceByPetNo(petNo int64) (*model.PetRegistration, error) {
	return s.queryDevice(`WHERE pet_no=?`, petNo)
}

// queryDevice 按条件查一台设备；查不到返回 (nil, nil)，交由业务层判定
func (s *SocialSQLite) queryDevice(where string, arg any) (*model.PetRegistration, error) {
	row := s.db.QueryRow(`SELECT device_id, pet_no, pet_name, hostname, first_seen_ms, last_seen_ms
		FROM devices `+where, arg)
	var (
		reg         model.PetRegistration
		first, last int64
	)
	err := row.Scan(&reg.DeviceID, &reg.PetNo, &reg.PetName, &reg.Hostname, &first, &last)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	reg.FirstSeenAt = millis(first)
	reg.LastSeenAt = millis(last)
	return &reg, nil
}

// ── 好友关系 ──────────────────────────────────────────────

func (s *SocialSQLite) Friends(deviceID string) ([]model.FriendEntry, error) {
	rows, err := s.db.Query(`SELECT friend_no, friend_name, added_ms FROM friends
		WHERE device_id=? ORDER BY added_ms, friend_no`, deviceID)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	out := []model.FriendEntry{}
	for rows.Next() {
		var (
			f   model.FriendEntry
			add int64
		)
		if err := rows.Scan(&f.PetNo, &f.PetName, &add); err != nil {
			return nil, err
		}
		f.AddedAt = millis(add)
		out = append(out, f)
	}
	return out, rows.Err()
}

func (s *SocialSQLite) IsFriend(deviceID string, petNo int64) (bool, error) {
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM friends WHERE device_id=? AND friend_no=? LIMIT 1`, deviceID, petNo).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	return err == nil, err
}

// MakeMutualFriends 双向各补一条好友；已存在的方向由主键冲突自动跳过，重复调用幂等
func (s *SocialSQLite) MakeMutualFriends(a, b *model.PetRegistration, now time.Time) error {
	stmt := `INSERT OR IGNORE INTO friends(device_id, friend_no, friend_name, added_ms) VALUES(?,?,?,?)`
	_, err := s.db.Exec(stmt, a.DeviceID, b.PetNo, b.PetName, now.UnixMilli())
	if err != nil {
		return err
	}
	_, err = s.db.Exec(stmt, b.DeviceID, a.PetNo, a.PetName, now.UnixMilli())
	return err
}

func (s *SocialSQLite) DropFriendship(ownerDeviceID string, otherPetNo int64, otherDeviceID string, ownerPetNo int64) error {
	if _, err := s.db.Exec(`DELETE FROM friends WHERE device_id=? AND friend_no=?`, ownerDeviceID, otherPetNo); err != nil {
		return err
	}
	_, err := s.db.Exec(`DELETE FROM friends WHERE device_id=? AND friend_no=?`, otherDeviceID, ownerPetNo)
	return err
}

// ── 好友申请 ──────────────────────────────────────────────

func (s *SocialSQLite) PutRequest(req *model.FriendRequest) error {
	_, err := s.db.Exec(`INSERT INTO requests(from_device, to_no, id, from_no, from_name, created_ms) VALUES(?,?,?,?,?,?)
		ON CONFLICT(from_device, to_no) DO UPDATE SET id=excluded.id, from_no=excluded.from_no,
			from_name=excluded.from_name, created_ms=excluded.created_ms`,
		req.FromDevice, req.ToPetNo, req.ID, req.FromPetNo, req.FromName, req.CreatedAt.UnixMilli())
	return err
}

// FindRequest 定位待处理申请（取最早一条）
func (s *SocialSQLite) FindRequest(toPetNo int64, fromDevice string, fromPetNo int64) (*model.FriendRequest, error) {
	q := `SELECT from_device, to_no, id, from_no, from_name, created_ms FROM requests WHERE to_no=?`
	args := []any{toPetNo}
	if fromDevice != "" {
		q += ` AND from_device=?`
		args = append(args, fromDevice)
	}
	if fromPetNo != 0 {
		q += ` AND from_no=?`
		args = append(args, fromPetNo)
	}
	q += ` ORDER BY created_ms LIMIT 1`

	var req model.FriendRequest
	var created int64
	err := s.db.QueryRow(q, args...).Scan(&req.FromDevice, &req.ToPetNo, &req.ID, &req.FromPetNo, &req.FromName, &created)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	req.CreatedAt = millis(created)
	return &req, nil
}

func (s *SocialSQLite) RequestsTo(toPetNo int64) ([]model.FriendRequest, error) {
	rows, err := s.db.Query(`SELECT from_device, to_no, id, from_no, from_name, created_ms FROM requests
		WHERE to_no=? ORDER BY created_ms`, toPetNo)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	out := []model.FriendRequest{}
	for rows.Next() {
		var (
			req     model.FriendRequest
			created int64
		)
		if err := rows.Scan(&req.FromDevice, &req.ToPetNo, &req.ID, &req.FromPetNo, &req.FromName, &created); err != nil {
			return nil, err
		}
		req.CreatedAt = millis(created)
		out = append(out, req)
	}
	return out, rows.Err()
}

// DropRequest 按申请 ID 删除一条待处理申请（处理后不再占位，结果已落留痕）
func (s *SocialSQLite) DropRequest(requestID string) error {
	_, err := s.db.Exec(`DELETE FROM requests WHERE id=?`, requestID)
	return err
}

func (s *SocialSQLite) DropRequestsBetween(devA string, petNoA int64, devB string, petNoB int64) error {
	_, err := s.db.Exec(`DELETE FROM requests WHERE
		(from_device=? AND to_no=?) OR (from_device=? AND to_no=?)`, devA, petNoB, devB, petNoA)
	return err
}

func (s *SocialSQLite) TrimRequests(keep int) error {
	_, err := s.db.Exec(`DELETE FROM requests WHERE id NOT IN (
		SELECT id FROM requests ORDER BY created_ms DESC LIMIT ?)`, keep)
	return err
}

// ── 消息 ──────────────────────────────────────────────

func (s *SocialSQLite) PushMessage(toDeviceID string, msg model.PetMessage, keepLast int) error {
	if _, err := s.db.Exec(`INSERT INTO messages(id, to_device, from_no, from_name, text, sent_ms) VALUES(?,?,?,?,?,?)`,
		msg.ID, toDeviceID, msg.FromPetNo, msg.FromName, msg.Text, msg.SentAt.UnixMilli()); err != nil {
		return err
	}
	// 每设备收件箱有界：超出丢弃最旧的（与新消息同时刻时按插入顺序判定）
	_, err := s.db.Exec(`DELETE FROM messages WHERE to_device=? AND id NOT IN (
		SELECT id FROM messages WHERE to_device=? ORDER BY sent_ms DESC, rowid DESC LIMIT ?)`,
		toDeviceID, toDeviceID, keepLast)
	return err
}

// PendingMessages 本次应下发：从未下发过的，或已过重投间隔且未超龄、未达次数上限的
func (s *SocialSQLite) PendingMessages(deviceID string, now time.Time, q PendingQuery) ([]model.PetMessage, error) {
	rows, err := s.db.Query(`SELECT id, from_no, from_name, text, sent_ms FROM messages
		WHERE to_device=? AND (delivered_ms IS NULL
			OR (sent_ms > ? AND deliver_times < ? AND delivered_ms <= ?))
		ORDER BY sent_ms, rowid`,
		deviceID, now.Add(-q.TTL).UnixMilli(), q.MaxDeliverTimes, now.Add(-q.RedeliverAfter).UnixMilli())
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var out []model.PetMessage
	for rows.Next() {
		var (
			msg    model.PetMessage
			sentAt int64
		)
		if err := rows.Scan(&msg.ID, &msg.FromPetNo, &msg.FromName, &msg.Text, &sentAt); err != nil {
			return nil, err
		}
		msg.SentAt = millis(sentAt)
		out = append(out, msg)
	}
	return out, rows.Err()
}

func (s *SocialSQLite) MarkDelivered(deviceID string, ids []string, at time.Time) error {
	if len(ids) == 0 {
		return nil
	}
	q := `UPDATE messages SET delivered_ms=?, deliver_times=deliver_times+1 WHERE to_device=? AND id IN (` + placeholders(len(ids)) + `)`
	_, err := s.db.Exec(q, append([]any{at.UnixMilli(), deviceID}, argsOf(ids)...)...)
	return err
}

func (s *SocialSQLite) DeleteMessages(deviceID string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	q := `DELETE FROM messages WHERE to_device=? AND id IN (` + placeholders(len(ids)) + `)`
	_, err := s.db.Exec(q, append([]any{deviceID}, argsOf(ids)...)...)
	return err
}

// ── 对话留痕 ──────────────────────────────────────────────

func (s *SocialSQLite) AppendHistory(rec model.PetConversationRecord, keepLast int) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`INSERT INTO history(kind, from_no, from_name, from_host, to_no, to_name, to_host,
		to_device, text, sent_ms, delivered_ms, read_ms, handled_ms, status)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		orDefault(rec.Kind, model.ConversationKindMessage), rec.FromPetNo, rec.FromName, rec.FromHost,
		rec.ToPetNo, rec.ToName, rec.ToHost, rec.ToDeviceID, rec.Text, rec.SentAt.UnixMilli(),
		nullMillis(rec.DeliveredAt), nullMillis(rec.ReadAt), nullMillis(rec.HandledAt), rec.Status)
	if err != nil {
		return err
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
			return err
		}
	}
	if keepLast > 0 {
		if _, err := tx.Exec(`DELETE FROM history WHERE seq NOT IN (
			SELECT seq FROM history ORDER BY seq DESC LIMIT ?)`, keepLast); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM history_ids WHERE seq NOT IN (SELECT seq FROM history)`); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *SocialSQLite) History(limit int) ([]model.PetConversationRecord, error) {
	// 取最近 limit 条，但展示顺序仍是旧 → 新（按 seq 倒序截断后再整序）
	q := `SELECT ` + historyColumns + ` FROM history`
	args := []any{}
	if limit > 0 {
		q += ` WHERE seq IN (SELECT seq FROM history ORDER BY seq DESC LIMIT ?)`
		args = append(args, limit)
	}
	q += ` ORDER BY seq ASC`

	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	out := []model.PetConversationRecord{}
	for rows.Next() {
		var (
			kind, fromName, fromHost string
			toName, toHost, toDevice string
			text, status, idsCSV     sql.NullString
			fromNo, toNo, sent       int64
			delivered, read, handled sql.NullInt64
		)
		if err := rows.Scan(&kind, &fromNo, &fromName, &fromHost, &toNo, &toName, &toHost, &toDevice, &text,
			&sent, &delivered, &read, &handled, &status, &idsCSV); err != nil {
			return nil, err
		}
		rec := model.PetConversationRecord{
			Kind: kind, Status: strOr(status, ""), Text: strOr(text, ""),
			FromPetNo: fromNo, FromName: fromName, FromHost: fromHost,
			ToPetNo: toNo, ToName: toName, ToHost: toHost, ToDeviceID: toDevice,
			SentAt:      millis(sent),
			DeliveredAt: timeOrZero(delivered),
			ReadAt:      timeOrZero(read),
			HandledAt:   timeOrZero(handled),
		}
		if s := strOr(idsCSV, ""); s != "" {
			rec.IDs = strings.Split(s, ",")
		}
		out = append(out, rec)
	}
	return out, rows.Err()
}

func (s *SocialSQLite) MarkRequestHandled(requestID, status string, at time.Time) error {
	_, err := s.db.Exec(`UPDATE history SET status=?, handled_ms=? WHERE kind=? AND EXISTS (
		SELECT 1 FROM history_ids WHERE history_ids.seq=history.seq AND history_ids.ref_id=?)`,
		status, at.UnixMilli(), model.ConversationKindRequest, requestID)
	return err
}

func (s *SocialSQLite) MarkHistoryDelivered(deviceID string, ids []string, at time.Time) error {
	if len(ids) == 0 {
		return nil
	}
	q := `UPDATE history SET delivered_ms=? WHERE delivered_ms IS NULL AND to_device=? AND EXISTS (
		SELECT 1 FROM history_ids WHERE history_ids.seq=history.seq AND history_ids.ref_id IN (` +
		placeholders(len(ids)) + `))`
	_, err := s.db.Exec(q, append([]any{at.UnixMilli(), deviceID}, argsOf(ids)...)...)
	return err
}

// MarkHistoryRead 给未读留痕盖已读时间，返回命中条数（供业务层判断是否重复确认）
func (s *SocialSQLite) MarkHistoryRead(deviceID string, ids []string, at time.Time) (int, error) {
	if len(ids) == 0 {
		return 0, nil
	}
	// 参数必须按 SQL 里占位符的出现顺序拼：设备条件要排在 ref_id 列表之前
	q := `UPDATE history SET read_ms=? WHERE read_ms IS NULL AND kind=?`
	args := []any{at.UnixMilli(), model.ConversationKindMessage}
	if deviceID != "" {
		q += ` AND to_device=?`
		args = append(args, deviceID)
	}
	q += ` AND EXISTS (
		SELECT 1 FROM history_ids WHERE history_ids.seq=history.seq AND history_ids.ref_id IN (` +
		placeholders(len(ids)) + `))`
	args = append(args, argsOf(ids)...)

	res, err := s.db.Exec(q, args...)
	if err != nil {
		return 0, err
	}
	hit, err := res.RowsAffected()
	return int(hit), err
}

func (s *SocialSQLite) ClearHistory() error {
	if _, err := s.db.Exec(`DELETE FROM history`); err != nil {
		return err
	}
	_, err := s.db.Exec(`DELETE FROM history_ids`)
	return err
}

// historyColumns 留痕的统一查询列（含关联 ID 的拼接），限条数与全量读都复用它
const historyColumns = `kind, from_no, from_name, from_host, to_no, to_name, to_host, to_device, text,
		sent_ms, delivered_ms, read_ms, handled_ms, status,
		(SELECT group_concat(ref_id, ',') FROM history_ids WHERE history_ids.seq=history.seq) AS ids`

// ── 小工具 ──────────────────────────────────────────────

// placeholders 生成 (?,?,?) 形式的占位符，参数一律走绑定、不拼字符串
func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// argsOf 把 ID 列表摊平成查询参数
func argsOf(ids []string) []any {
	out := make([]any, 0, len(ids))
	for _, id := range ids {
		out = append(out, id)
	}
	return out
}

// millis 整数时间戳还原为时间
func millis(ms int64) time.Time { return time.UnixMilli(ms) }

// nullMillis 零值时间写成 NULL（表示「还没发生」），避免和业务时间混在一起
func nullMillis(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UnixMilli()
}

// timeOrZero NULL 列还原为零值时间
func timeOrZero(v sql.NullInt64) time.Time {
	if !v.Valid {
		return time.Time{}
	}
	return millis(v.Int64)
}

// strOr NULL 字符串列取值，NULL 时回退默认串
func strOr(v sql.NullString, fallback string) string {
	if v.Valid {
		return v.String
	}
	return fallback
}

func orDefault(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}
