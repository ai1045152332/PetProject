package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/gif"
	_ "image/jpeg"
	_ "image/png"
	"log"
	"os"
	"path/filepath"
	"petserver/internal/storage"
	"strings"
	"sync"
	"time"
)

const MaxPetImageBytes = 10 << 20

// Bound decoded dimensions as well as compressed bytes to prevent decompression bombs.
const MaxPetImagePixels = 40_000_000

type PetImage struct {
	State            string    `json:"state,omitempty"`
	ID               string    `json:"id"`
	Name             string    `json:"name"`
	ContentType      string    `json:"contentType"`
	CreatedAt        time.Time `json:"createdAt"`
	Status           string    `json:"status,omitempty"`
	Error            string    `json:"error,omitempty"`
	SourceID         string    `json:"sourceId,omitempty"`
	PromptVersion    string    `json:"promptVersion,omitempty"`
	SelectionVersion int       `json:"selectionVersion,omitempty"`
}
type PetImageLibrary struct {
	CurrentIDs        map[string]string `json:"currentIds,omitempty"`
	SelectionVersions map[string]int    `json:"selectionVersions,omitempty"`
	CurrentID         string            `json:"currentId"`
	Images            []PetImage        `json:"images"`
	SelectionVersion  int               `json:"selectionVersion,omitempty"`
	GenerationDay     string            `json:"generationDay,omitempty"`
	GenerationCount   int               `json:"generationCount,omitempty"`
}
type PetImageService struct {
	mu        sync.Mutex
	root      string
	objects   storage.PetImageObjects
	generator PetImageGenerator
	slots     chan struct{}
	ctx       context.Context
	cancel    context.CancelFunc
	workers   sync.WaitGroup
}

func NewPetImageService(root string, objects storage.PetImageObjects) (*PetImageService, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &PetImageService{root: root, objects: objects, slots: make(chan struct{}, 2), ctx: ctx, cancel: cancel}
	// Do not silently repeat billed OpenRouter calls after a restart. Keep originals for explicit retry.
	files, err := os.ReadDir(root)
	if err != nil {
		cancel()
		return nil, err
	}
	for _, file := range files {
		if file.IsDir() || filepath.Ext(file.Name()) != ".json" {
			continue
		}
		key := strings.TrimSuffix(file.Name(), ".json")
		lib, err := s.loadKey(key)
		if err != nil {
			cancel()
			return nil, err
		}
		changed := false
		for i := range lib.Images {
			if petGenerating(lib.Images[i].Status) {
				lib.Images[i].Status = "failed"
				lib.Images[i].Error = "服务重启中断了生成，请在历史图片中重试"
				changed = true
			}
		}
		if changed {
			if err = s.saveKey(key, lib); err != nil {
				cancel()
				return nil, err
			}
		}
	}
	return s, nil
}
func deviceImageKey(device string) string {
	sum := sha256.Sum256([]byte(device))
	return hex.EncodeToString(sum[:])
}
func (s *PetImageService) load(device string) (PetImageLibrary, error) {
	return s.loadKey(deviceImageKey(device))
}
func (s *PetImageService) loadKey(key string) (PetImageLibrary, error) {
	lib := PetImageLibrary{Images: []PetImage{}}
	data, err := os.ReadFile(filepath.Join(s.root, key+".json"))
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
	return s.saveKey(deviceImageKey(device), lib)
}
func (s *PetImageService) saveKey(key string, lib PetImageLibrary) error {
	data, err := json.Marshal(lib)
	if err != nil {
		return err
	}
	return storage.AtomicPetWrite(filepath.Join(s.root, key+".json"), data)
}
func (s *PetImageService) List(device string) (PetImageLibrary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.load(device)
}
func (s *PetImageService) Upload(device, name string, data []byte, states ...string) (PetImageLibrary, error) {
	state, err := petTargetState(states)
	if err != nil {
		return PetImageLibrary{}, err
	}
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
	if err = s.admit(&lib); err != nil {
		return lib, err
	}
	var id, source [16]byte
	if _, err = rand.Read(id[:]); err != nil {
		<-s.slots
		return lib, err
	}
	if _, err = rand.Read(source[:]); err != nil {
		<-s.slots
		return lib, err
	}
	item := PetImage{ID: hex.EncodeToString(id[:]), SourceID: hex.EncodeToString(source[:]), Name: filepath.Base(name), CreatedAt: time.Now().UTC(), ContentType: "image/gif", Status: "beautifying", PromptVersion: PetPromptVersion, SelectionVersion: lib.selectionVersion(state), State: state}
	key := deviceImageKey(device)
	if err = s.objects.Put(key+"/"+item.SourceID, data); err != nil {
		<-s.slots
		return lib, err
	}
	lib.Images = append([]PetImage{item}, lib.Images...)
	if err = s.save(device, lib); err != nil {
		_ = s.objects.Delete(key + "/" + item.SourceID)
		<-s.slots
		return PetImageLibrary{}, err
	}
	s.launch(key, item)
	return lib, nil
}

var ErrPetGenerationDisabled = errors.New("服务端尚未配置 OPENROUTER_API_KEY，无法生成宠物动画")
var ErrPetGenerationBusy = errors.New("生成任务繁忙，请稍后重试")

func petGenerating(status string) bool {
	return status == "beautifying" || status == "animating" || status == "encoding"
}
func petReady(item PetImage) bool { return item.Status == "" || item.Status == "ready" }
func (s *PetImageService) SetGenerator(generator PetImageGenerator) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.generator = generator
}
func (s *PetImageService) Close() { s.cancel(); s.workers.Wait() }
func (s *PetImageService) admit(lib *PetImageLibrary) error {
	if s.generator == nil {
		return ErrPetGenerationDisabled
	}
	if s.ctx.Err() != nil {
		return ErrPetGenerationDisabled
	}
	for _, item := range lib.Images {
		if petGenerating(item.Status) {
			return ErrPetGenerationBusy
		}
	}
	day := time.Now().UTC().Format("2006-01-02")
	if lib.GenerationDay != day {
		lib.GenerationDay = day
		lib.GenerationCount = 0
	}
	if lib.GenerationCount >= 10 {
		return errors.New("此设备今日已生成 10 次，请明天再试")
	}
	select {
	case s.slots <- struct{}{}:
		lib.GenerationCount++
		return nil
	default:
		return ErrPetGenerationBusy
	}
}
func (s *PetImageService) Retry(device, id string, states ...string) (PetImageLibrary, error) {
	state, stateErr := petTargetState(states)
	if stateErr != nil {
		return PetImageLibrary{}, stateErr
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	lib, err := s.load(device)
	if err != nil {
		return lib, err
	}
	for i := range lib.Images {
		item := &lib.Images[i]
		if item.ID != id {
			continue
		}
		if state == "" {
			state = item.State
		}
		if item.State != "" && item.State != state {
			return lib, errors.New("该图片不属于所选状态")
		}
		if item.Status != "failed" || item.SourceID == "" {
			return lib, errors.New("仅可重试生成失败的图片")
		}
		if err = s.admit(&lib); err != nil {
			return lib, err
		}
		item.State = state
		item.Status = "beautifying"
		item.PromptVersion = PetPromptVersion
		item.Error = ""
		item.SelectionVersion = lib.selectionVersion(item.State)
		if err = s.save(device, lib); err != nil {
			<-s.slots
			return lib, err
		}
		s.launch(deviceImageKey(device), *item)
		return lib, nil
	}
	return lib, os.ErrNotExist
}
func (s *PetImageService) launch(key string, item PetImage) {
	generator := s.generator
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		defer func() { <-s.slots }()
		ctx, cancel := context.WithTimeout(s.ctx, 9*time.Minute)
		defer cancel()
		progress := func(stage string) {
			s.mu.Lock()
			defer s.mu.Unlock()
			lib, err := s.loadKey(key)
			if err != nil {
				return
			}
			for i := range lib.Images {
				if lib.Images[i].ID == item.ID {
					lib.Images[i].Status = stage
				}
			}
			if err = s.saveKey(key, lib); err != nil {
				log.Printf("[pet-images] progress persistence failed: %v", err)
			}
		}
		source, err := s.objects.Get(key + "/" + item.SourceID)
		var output []byte
		if err == nil {
			output, err = generator.Generate(ctx, source, progress)
		}
		if err == nil {
			var animation *gif.GIF
			animation, err = gif.DecodeAll(bytes.NewReader(output))
			if err == nil && len(animation.Image) < 2 {
				err = errors.New("生成结果不是多帧 GIF")
			}
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		lib, loadErr := s.loadKey(key)
		if loadErr != nil {
			log.Printf("[pet-images] result persistence failed: %v", loadErr)
			return
		}
		for i := range lib.Images {
			if lib.Images[i].ID != item.ID {
				continue
			}
			if err == nil {
				err = s.objects.Put(key+"/"+item.ID, output)
			}
			if err != nil {
				lib.Images[i].Status = "failed"
				lib.Images[i].Error = err.Error()
			} else {
				lib.Images[i].Status = "ready"
				lib.Images[i].Error = ""
				// A manual selection/reset during generation takes precedence over automatic replacement.
				if lib.selectionVersion(item.State) == item.SelectionVersion {
					lib.selectImage(item.State, item.ID)
				}
			}
			if saveErr := s.saveKey(key, lib); saveErr != nil {
				log.Printf("[pet-images] result persistence failed: %v", saveErr)
			}
			return
		}
	}()
}
func (s *PetImageService) Select(device, id string, states ...string) (PetImageLibrary, error) {
	state, stateErr := petTargetState(states)
	if stateErr != nil {
		return PetImageLibrary{}, stateErr
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	lib, err := s.load(device)
	if err != nil {
		return lib, err
	}
	found := id == ""
	for _, item := range lib.Images {
		if item.ID == id && petReady(item) && (item.State == state || item.State == "") {
			found = true
		}
	}
	if !found {
		return lib, os.ErrNotExist
	}
	lib.selectImage(state, id)
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
		if item.ID == id && petReady(item) {
			data, err := s.objects.Get(deviceImageKey(device) + "/" + id)
			return data, item.ContentType, err
		}
	}
	return nil, "", os.ErrNotExist
}

// Empty state is the legacy shared image. Explicit state overrides, including an empty
// image ID (reset), take precedence so resetting one state never restores a legacy shared image.
func petTargetState(states []string) (string, error) {
	if len(states) == 0 || states[0] == "" {
		return "", nil
	}
	switch states[0] {
	case "focus", "idel", "warn", "sleep", "pet":
		return states[0], nil
	}
	return "", errors.New("无效的宠物状态")
}
func (lib PetImageLibrary) selectedID(state string) string {
	if id, ok := lib.CurrentIDs[state]; ok {
		return id
	}
	return lib.CurrentID
}
func (lib PetImageLibrary) selectionVersion(state string) int {
	if state == "" {
		return lib.SelectionVersion
	}
	return lib.SelectionVersions[state]
}
func (lib *PetImageLibrary) selectImage(state, id string) {
	if state == "" {
		lib.CurrentID = id
		lib.SelectionVersion++
		return
	}
	if lib.CurrentIDs == nil {
		lib.CurrentIDs = make(map[string]string)
	}
	if lib.SelectionVersions == nil {
		lib.SelectionVersions = make(map[string]int)
	}
	lib.CurrentIDs[state] = id
	lib.SelectionVersions[state]++
}
