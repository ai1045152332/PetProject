package storage

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// PetImageObjects can be implemented by a third-party object storage adapter.
// Keys are opaque, server-generated identifiers; no public URL is persisted.
type PetImageObjects interface {
	Put(key string, data []byte) error
	Get(key string) ([]byte, error)
	Delete(key string) error
}
type LocalPetImageObjects struct{ root string }

// petObjectKey guards object paths against traversal: the first segment is always the server-side
// SHA-256 device key (64 lowercase hex), the optional second is the upload batch folder
// (YYYYMMDD-HHMMSS-<6 hex>), and the last is a human-readable file name that must not contain '/'
// and must not start with '.' (so "..", absolute or deeper nested paths are rejected even though the
// name stem originates from a client-supplied file name). Keys written before batch folders existed
// (device/name) stay valid.
var petObjectKey = regexp.MustCompile(`^[a-f0-9]{64}/(?:[0-9]{8}-[0-9]{6}-[a-f0-9]{6}/)?[^./][^/]{0,127}$`)

func NewLocalPetImageObjects(root string) (*LocalPetImageObjects, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	return &LocalPetImageObjects{root: root}, nil
}
func (s *LocalPetImageObjects) path(key string) (string, error) {
	if !petObjectKey.MatchString(key) {
		return "", fmt.Errorf("invalid object key")
	}
	return filepath.Join(s.root, filepath.FromSlash(key)), nil
}
func (s *LocalPetImageObjects) Put(key string, data []byte) error {
	p, err := s.path(key)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		return err
	}
	return AtomicPetWrite(p, data)
}
func (s *LocalPetImageObjects) Get(key string) ([]byte, error) {
	p, err := s.path(key)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(p)
}
func (s *LocalPetImageObjects) Delete(key string) error {
	p, err := s.path(key)
	if err != nil {
		return err
	}
	if err = os.Remove(p); err != nil {
		return err
	}
	// Drop the now-empty upload folder so objects/<device>/ never accumulates empty batches.
	if dir := filepath.Dir(p); filepath.Dir(dir) != s.root && filepath.Dir(filepath.Dir(dir)) == s.root {
		_ = os.Remove(dir)
	}
	return nil
}
func AtomicPetWrite(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".pet-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
