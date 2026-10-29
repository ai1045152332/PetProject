// Command dbpeek 只读查看好友与宠物消息的线上状态，供排障使用。
//
// 典型场景：某只宠物说「没收到好友申请」，需要确认申请到底落在服务端队列里、
// 还是已被处理/覆盖；以及心跳是否真的把它下发给了接收方。
//
// 用法：
//
//	dbpeek                       # 默认读 /opt/petserver/data/petserver.db（服务器上）
//	dbpeek -db /path/petserver.db  # 本地验证一份库快照
//
// 一律以 mode=ro 打开，不建表、不升级、不写入任何一行；需要变更状态请走服务本身。
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"os"
	"time"

	_ "github.com/ncruces/go-sqlite3/driver"
)

func main() {
	dbPath := flag.String("db", "/opt/petserver/data/petserver.db", "SQLite 库路径")
	flag.Parse()

	db, err := sql.Open("sqlite3", "file:"+*dbPath+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		fmt.Fprintln(os.Stderr, "打开库失败:", err)
		os.Exit(1)
	}
	defer db.Close()

	fmt.Println("== 设备与宠物号 ==")
	query(db, `SELECT pet_no, pet_name, hostname, device_id, datetime(last_seen_ms/1000,'unixepoch','localtime')
		FROM devices ORDER BY pet_no`,
		"号", "名字", "主机", "设备ID", "最近心跳")

	fmt.Println("== 待处理好友申请（按接收方）==")
	n := query(db, `SELECT to_no, from_no, from_name, from_device, id, datetime(created_ms/1000,'unixepoch','localtime')
		FROM requests ORDER BY to_no, created_ms`,
		"接收方#", "发起方#", "发起方名字", "发起方设备", "申请ID", "发起时间")
	if n == 0 {
		fmt.Println("(队列为空：此时任何接收方心跳都不会收到申请；若确有申请发出过，看下面的留痕)")
	}

	fmt.Println("== 好友申请留痕（最近 20 条，含被覆盖/已处理的）==")
	query(db, `SELECT from_no, from_name, to_no, to_name, status, datetime(sent_ms/1000,'unixepoch','localtime'),
		COALESCE(datetime(handled_ms/1000,'unixepoch','localtime'),'-')
		FROM history WHERE kind='request' ORDER BY seq DESC LIMIT 20`,
		"发起方#", "名字", "接收方#", "接收方名字", "状态", "发起时间", "处理时间")

	fmt.Println("== 好友关系 ==")
	query(db, `SELECT d.pet_no, d.pet_name, f.friend_no, f.friend_name, datetime(f.added_ms/1000,'unixepoch','localtime')
		FROM friends f LEFT JOIN devices d ON d.device_id=f.device_id ORDER BY f.added_ms`,
		"号", "名字", "好友#", "好友名字", "添加时间")

	fmt.Println("== 未确认已读的消息 ==")
	query(db, `SELECT to_device, from_no, from_name, substr(text,1,30), datetime(sent_ms/1000,'unixepoch','localtime'),
		deliver_times, COALESCE(datetime(delivered_ms/1000,'unixepoch','localtime'),'未下发')
		FROM messages ORDER BY sent_ms DESC LIMIT 20`,
		"接收设备", "发起#", "名字", "正文", "发送时间", "下发次数", "最近下发")

	var nextPetNo int64
	if err := db.QueryRow(`SELECT value FROM meta WHERE key='next_pet_no'`).Scan(&nextPetNo); err == nil {
		fmt.Printf("宠物号水位 next_pet_no=%d | 本机时间 %s\n", nextPetNo, time.Now().Format(time.RFC3339))
	}
}

// query 执行一条只读查询并按 | 分隔打印（带表头），返回打印行数
func query(db *sql.DB, q string, headers ...string) int {
	rows, err := db.Query(q)
	if err != nil {
		fmt.Println("查询失败:", err)
		return 0
	}
	defer func() { _ = rows.Close() }()

	for i, h := range headers {
		if i > 0 {
			fmt.Print(" | ")
		}
		fmt.Print(h)
	}
	fmt.Println()

	count := 0
	cols, err := rows.Columns()
	if err != nil {
		fmt.Println("取列失败:", err)
		return 0
	}
	for rows.Next() {
		vals := make([]any, len(cols))
		for i := range vals {
			vals[i] = new(any)
		}
		if err := rows.Scan(vals...); err != nil {
			fmt.Println("读取行失败:", err)
			return count
		}
		for i, v := range vals {
			if i > 0 {
				fmt.Print(" | ")
			}
			fmt.Print(stringify(*(v.(*any))))
		}
		fmt.Println()
		count++
	}
	if err := rows.Err(); err != nil {
		fmt.Println("遍历失败:", err)
	}
	return count
}

func stringify(v any) string {
	switch t := v.(type) {
	case nil:
		return "-"
	case []byte:
		return string(t)
	default:
		return fmt.Sprint(t)
	}
}
