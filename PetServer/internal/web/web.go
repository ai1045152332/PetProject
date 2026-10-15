// Package web 内置 H5 静态页面（随二进制打包，无需外部文件）
package web

import _ "embed"

// OnlinePage 在线宠物列表 H5 页面内容
//
//go:embed online.html
var OnlinePage []byte
