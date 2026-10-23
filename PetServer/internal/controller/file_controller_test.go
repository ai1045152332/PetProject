package controller

import (
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"petserver/internal/service"
)

// newFileCtrlForTest 在临时目录里搭好文件管理控制器：根目录下一个普通文件与一个敏感文件
func newFileCtrlForTest(t *testing.T) (*FileController, string) {
	t.Helper()

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "wordbank.json"), []byte(`{"words":["cat"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "宠物词库.txt"), []byte("猫\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "宠物配置.env"), []byte("PETSERVER_ADMIN_TOKEN=secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "dist"), 0o755); err != nil {
		t.Fatal(err)
	}

	fileSvc, err := service.NewFileService(dir)
	if err != nil {
		t.Fatal(err)
	}
	authSvc := service.NewAuthService("admin", "admin-pass", "")
	return NewFileController(authSvc, fileSvc), dir
}

// TestFileDownload 覆盖下载鉴权、正常下载、敏感文件与路径越界拦截
func TestFileDownload(t *testing.T) {
	ctrl, _ := newFileCtrlForTest(t)

	// 未带会话令牌/管理密码：一律 401，不能把文件放出去
	w := httptest.NewRecorder()
	ctrl.Download(w, httptest.NewRequest("GET", "/api/admin/files/download?path=wordbank.json", nil))
	if w.Code != 401 {
		t.Fatalf("unauthorized download: got %d, want 401", w.Code)
	}

	// 普通文件：流式返回原文，并带上强制下载与文件名
	w = httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/api/admin/files/download?path=wordbank.json", nil)
	r.Header.Set("X-Admin-Token", "admin-pass")
	ctrl.Download(w, r)
	if w.Code != 200 {
		t.Fatalf("download: got %d %s", w.Code, w.Body.String())
	}
	if got := w.Body.String(); got != `{"words":["cat"]}` {
		t.Fatalf("download body = %s", got)
	}
	disp := w.Header().Get("Content-Disposition")
	if !strings.HasPrefix(disp, "attachment;") || !strings.Contains(disp, "wordbank.json") {
		t.Fatalf("Content-Disposition = %s", disp)
	}

	// 中文文件名：按 RFC 5987 用 filename* 传递，避免下载后变成乱码
	w = httptest.NewRecorder()
	r = httptest.NewRequest("GET", "/api/admin/files/download?path="+url.QueryEscape("宠物词库.txt"), nil)
	r.Header.Set("X-Admin-Token", "admin-pass")
	ctrl.Download(w, r)
	if w.Code != 200 {
		t.Fatalf("download chinese name: got %d %s", w.Code, w.Body.String())
	}
	if disp := w.Header().Get("Content-Disposition"); !strings.Contains(disp, "filename*=UTF-8''") {
		t.Fatalf("Content-Disposition = %s", disp)
	}

	// 敏感文件（.env/.pem/.key/sessions.json）禁止下载，防止后台密码与私钥外流
	w = httptest.NewRecorder()
	r = httptest.NewRequest("GET", "/api/admin/files/download?path="+url.QueryEscape("宠物配置.env"), nil)
	r.Header.Set("X-Admin-Token", "admin-pass")
	ctrl.Download(w, r)
	if w.Code != 400 {
		t.Fatalf("sensitive download: got %d %s, want 400", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), "secret") {
		t.Fatal("sensitive file content leaked")
	}

	// 目录与越界路径都不允许下载
	for _, path := range []string{"dist", "../etc/passwd"} {
		w = httptest.NewRecorder()
		r = httptest.NewRequest("GET", "/api/admin/files/download?path="+path, nil)
		r.Header.Set("X-Admin-Token", "admin-pass")
		ctrl.Download(w, r)
		if w.Code != 400 {
			t.Fatalf("download %q: got %d %s, want 400", path, w.Code, w.Body.String())
		}
	}

	// 缺少 path 参数：直接报参数错误，不落到文件系统
	w = httptest.NewRecorder()
	r = httptest.NewRequest("GET", "/api/admin/files/download", nil)
	r.Header.Set("X-Admin-Token", "admin-pass")
	ctrl.Download(w, r)
	if w.Code != 400 {
		t.Fatalf("missing path: got %d, want 400", w.Code)
	}
}
