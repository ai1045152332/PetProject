// Package web 内置 H5 静态页面（随二进制打包，无需外部文件）
package web

import "embed"

// OnlinePage 在线宠物列表 H5 页面内容
//
//go:embed online.html
var OnlinePage []byte

// AdminPage 激活码管理 H5 页面内容
//
//go:embed admin.html
var AdminPage []byte

// StaticFS 内置静态资源（Tabler 后台 UI 框架样式等）
//
//go:embed static
var StaticFS embed.FS
