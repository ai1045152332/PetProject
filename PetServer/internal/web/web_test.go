package web

import (
	"os"
	"strings"
	"testing"
)

// TestAdminPagesShareSingleNav 后台页导航栏必须只有一处来源：
// 菜单由 static/admin-nav.js 统一渲染，各页只保留占位符，
// 防止再出现「每个页面各复制一份 <header>、切页时菜单顺序跳动」的问题。
func TestAdminPagesShareSingleNav(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("读取页面目录失败: %v", err)
	}

	var checked int
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, "admin_") || !strings.HasSuffix(name, ".html") {
			continue
		}
		// 登录页在导航之外（登录前无菜单），不参与校验
		if name == "admin_login.html" {
			continue
		}
		checked++

		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", name, err)
		}
		html := string(data)

		for _, forbidden := range []string{
			`<header class="navbar`,                   // 页面内自绘导航栏（顺序会各页不一致）
			"function session()",                      // 重复定义的会话取值
			"function logout()",                       // 重复定义的退出逻辑
			"localStorage.getItem('petAdminSession')", // 页内内联登录守卫
		} {
			if strings.Contains(html, forbidden) {
				t.Errorf("%s 不应包含 %q：导航栏/守卫/session/logout 统一由 static/admin-nav.js 提供", name, forbidden)
			}
		}

		for _, required := range []string{
			`<div id="petAdminNav"></div>`,
			`src="/static/admin-nav.js?v=`,
		} {
			if !strings.Contains(html, required) {
				t.Errorf("%s 缺少 %q：应引用共享导航脚本并保留占位符", name, required)
			}
		}
	}

	if checked == 0 {
		t.Fatal("未检查到任何后台管理页，校验可能已失效")
	}
}

// TestAdminNavMenuSingleSource 菜单顺序与引用版本号必须集中在 admin-nav.js：
// 顺序只定义一次，且各页引用同一版本（静态资源一周强缓存，靠 ?v= 刷新生效）。
func TestAdminNavMenuSingleSource(t *testing.T) {
	data, err := os.ReadFile("static/admin-nav.js")
	if err != nil {
		t.Fatalf("读取 static/admin-nav.js 失败（菜单顺序的唯一定义处）: %v", err)
	}
	nav := string(data)

	// 期望顺序：与数组内的书写顺序一致，改动需同步这里
	want := []string{"/admin", "/admin/codes", "/admin/social", "/admin/status", "/admin/files"}
	prev := -1
	for _, href := range want {
		i := strings.Index(nav, `{ href: '`+href+"', label:")
		if i < 0 {
			t.Fatalf("admin-nav.js 菜单缺少 %s", href)
		}
		if i < prev {
			t.Fatalf("admin-nav.js 菜单顺序不符合约定：%s 位置异常", href)
		}
		prev = i
	}

	// 各页引用的 ?v= 必须一致，否则改一处 nav 只会对部分页面生效
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("读取页面目录失败: %v", err)
	}
	version := ""
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, "admin_") || !strings.HasSuffix(name, ".html") || name == "admin_login.html" {
			continue
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("读取 %s 失败: %v", name, err)
		}
		mark := `admin-nav.js?v=`
		html := string(data)
		i := strings.Index(html, mark)
		if i < 0 {
			t.Fatalf("%s 未引用 admin-nav.js", name)
		}
		rest := html[i+len(mark):]
		v := rest[:strings.IndexByte(rest, '"')]
		if version == "" {
			version = v
		} else if v != version {
			t.Errorf("各页 admin-nav.js 的 ?v= 不一致：%s 为 %s，其余为 %s", name, v, version)
		}
	}
}
