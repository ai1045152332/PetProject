package service

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"path/filepath"
	"petserver/internal/storage"
	"sync"
	"time"
)

const MaxPetImageBytes = 10 << 20

// Bound decoded dimensions as well as compressed bytes to prevent decompression bombs.
const MaxPetImagePixels = 40_000_000

type PetImage struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	ContentType string    `json:"contentType"`
	CreatedAt   time.Time `json:"createdAt"`
}
type PetImageLibrary struct {
	CurrentID string     `json:"currentId"`
	Images    []PetImage `json:"images"`
}
type PetImageService struct {
	mu      sync.Mutex
	root    string
	objects storage.PetImageObjects
}

func NewPetImageService(root string, objects storage.PetImageObjects) (*PetImageService, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	return &PetImageService{root: root, objects: objects}, nil
}
func deviceImageKey(device string) string {
	sum := sha256.Sum256([]byte(device))
	return hex.EncodeToString(sum[:])
}
func (s *PetImageService) load(device string) (PetImageLibrary, error) {
	lib := PetImageLibrary{Images: []PetImage{}}
	data, err := os.ReadFile(filepath.Join(s.root, deviceImageKey(device)+".json"))
	if os.IsNotExist(err) {
		return lib, nil
	}
	if err != nil {
		return lib, err
	}
	err = json.Unmarshal(data, &lib)
	return lib, err
}
func (s *PetImageService) save(device string, lib PetImageLibrary) error {
	data, err := json.Marshal(lib)
	if err != nil {
		return err
	}
	return storage.AtomicPetWrite(filepath.Join(s.root, deviceImageKey(device)+".json"), data)
}
func (s *PetImageService) List(device string) (PetImageLibrary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.load(device)
}
func (s *PetImageService) Upload(device, name string, data []byte) (PetImageLibrary, error) {
	if len(data) == 0 || len(data) > MaxPetImageBytes {
		return PetImageLibrary{}, fmt.Errorf("图片不得超过 10 MB")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "png" && format != "jpeg") {
		return PetImageLibrary{}, fmt.Errorf("仅支持有效的 PNG/JPEG 图片")
	}
	if config.Width <= 0 || config.Height <= 0 || int64(config.Width)*int64(config.Height) > MaxPetImagePixels {
		return PetImageLibrary{}, fmt.Errorf("图片像素不得超过 4000 万")
	}
	if _, _, err = image.Decode(bytes.NewReader(data)); err != nil {
		return PetImageLibrary{}, fmt.Errorf("图片数据损坏")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	lib, err := s.load(device)
	if err != nil {
		return lib, err
	}
	var id [16]byte
	if _, err = rand.Read(id[:]); err != nil {
		return lib, err
	}
	item := PetImage{ID: hex.EncodeToString(id[:]), Name: filepath.Base(name), ContentType: "image/" + format, CreatedAt: time.Now().UTC()}
	key := deviceImageKey(device) + "/" + item.ID
	if err = s.objects.Put(key, data); err != nil {
		return lib, err
	}
	lib.Images = append([]PetImage{item}, lib.Images...)
	lib.CurrentID = item.ID
	if err = s.save(device, lib); err != nil {
		_ = s.objects.Delete(key)
		return PetImageLibrary{}, err
	}
	return lib, nil
}
func (s *PetImageService) Select(device, id string) (PetImageLibrary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	lib, err := s.load(device)
	if err != nil {
		return lib, err
	}
	found := id == ""
	for _, item := range lib.Images {
		if item.ID == id {
			found = true
		}
	}
	if !found {
		return lib, os.ErrNotExist
	}
	lib.CurrentID = id
	return lib, s.save(device, lib)
}
func (s *PetImageService) Read(device, id string) ([]byte, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	lib, err := s.load(device)
	if err != nil {
		return nil, "", err
	}
	for _, item := range lib.Images {
		if item.ID == id {
			data, err := s.objects.Get(deviceImageKey(device) + "/" + id)
			return data, item.ContentType, err
		}
	}
	return nil, "", os.ErrNotExist
}
