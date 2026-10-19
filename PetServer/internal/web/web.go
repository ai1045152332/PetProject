// Package web 内置 H5 静态页面（随二进制打包，无需外部文件）
package web

import "embed"

// OnlinePage 在线宠物列表 H5 页面内容
//
//go:embed online.html
var OnlinePage []byte

// AdminPetsPage 后台管理：在线宠物页
//
//go:embed admin_pets.html
var AdminPetsPage []byte

// AdminLoginPage 后台管理：登录页
//
//go:embed admin_login.html
var AdminLoginPage []byte

// AdminCodesPage 后台管理：激活码管理页
//
//go:embed admin_codes.html
var AdminCodesPage []byte

// AdminFilesPage 后台管理：文件管理页
//
//go:embed admin_files.html
var AdminFilesPage []byte

// StaticFS 内置静态资源（Tabler 后台 UI 框架样式等）
//
//go:embed static
var StaticFS embed.FS
