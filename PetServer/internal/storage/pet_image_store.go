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

var petObjectKey = regexp.MustCompile(`^[a-f0-9]{64}/[a-f0-9]{32}$`)

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
