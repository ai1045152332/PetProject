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
// SHA-256 device key (64 lowercase hex), the second is a human-readable image name that must not
// contain '/' and must not start with '.' (so "..", absolute or nested paths are rejected even
// though the name stem originates from a client-supplied file name).
var petObjectKey = regexp.MustCompile(`^[a-f0-9]{64}/[^./][^/]{0,127}$`)

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
	return os.Remove(p)
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
