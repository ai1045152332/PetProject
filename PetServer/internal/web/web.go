// Package web 内置 H5 静态页面（随二进制打包，无需外部文件）
package web

import "embed"

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

// AdminStatusPage 后台管理：服务器状态页（CPU/内存/网络监控）
//
//go:embed admin_status.html
var AdminStatusPage []byte

// StaticFS 内置静态资源（Tabler 后台 UI 框架样式等）
//
//go:embed static
var StaticFS embed.FS

// SiteFS 官网落地页（cute pet 介绍 + 下载入口），随二进制打包，由后端在根路径 / 托管
// 与 /api/app/latest 同源，官网可直接动态获取最新版本、无需跨域
//
//go:embed site
var SiteFS embed.FS
