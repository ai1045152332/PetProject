// Package tlsreloader 提供 TLS 证书热加载：证书文件更新后自动切换，无需重启服务。
// 用于配合 certbot 自动续期（Let's Encrypt 证书 90 天有效）。
package tlsreloader

import (
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"sync"
	"time"
)

// Reloader 持有当前证书并按文件变化自动重新加载
type Reloader struct {
	mu       sync.RWMutex
	cert     *tls.Certificate
	certFile string
	keyFile  string
	sig      fileSignature // 上次加载时的文件特征，用于检测变化
}

type fileSignature struct {
	size    int64
	modTime int64
	inode   uint64
}

// New 读取证书并启动每分钟一次的变化检测；加载失败返回错误。
func New(certFile, keyFile string) (*Reloader, error) {
	r := &Reloader{certFile: certFile, keyFile: keyFile}
	if err := r.load(); err != nil {
		return nil, err
	}
	go r.watchLoop()
	return r, nil
}

// GetCertificate 供 tls.Config 使用，返回当前证书
func (r *Reloader) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cert, nil
}

func (r *Reloader) load() error {
	cert, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		return fmt.Errorf("加载 TLS 证书失败: %w", err)
	}
	sig, err := signature(r.certFile)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.cert, r.sig = &cert, sig
	r.mu.Unlock()
	return nil
}

// watchLoop 每 30 秒检查一次证书文件是否更新（续期后 live/ 符号链接指向的文件会变化）
func (r *Reloader) watchLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		sig, err := signature(r.certFile)
		if err != nil {
			continue
		}
		r.mu.RLock()
		unchanged := sig == r.sig
		r.mu.RUnlock()
		if unchanged {
			continue
		}
		if err := r.load(); err != nil {
			log.Printf("[tls] 证书热加载失败（保留旧证书）: %v", err)
			continue
		}
		log.Printf("[tls] 检测到证书更新，已热加载: %s", r.certFile)
	}
}

func signature(path string) (fileSignature, error) {
	info, err := os.Stat(path)
	if err != nil {
		return fileSignature{}, err
	}
	return fileSignature{size: info.Size(), modTime: info.ModTime().UnixNano()}, nil
}
