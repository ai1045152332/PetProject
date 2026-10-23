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
	"unicode"
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
	// Lifetime generation quota measured per activation code, shared across every bound device.
	GenerationLimit     int `json:"generationLimit,omitempty"`
	GenerationRemaining int `json:"generationRemaining,omitempty"`
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
	codeQuota int
	// quotaFor resolves the per-code lifetime image-generation limit from the activation code.
	// When nil (tests / unwired), the service falls back to the static codeQuota field.
	quotaFor func(code string) int
}

func NewPetImageService(root string, objects storage.PetImageObjects) (*PetImageService, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &PetImageService{root: root, objects: objects, slots: make(chan struct{}, 2), ctx: ctx, cancel: cancel, codeQuota: 0}
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

// petImageFileLabel turns a client-supplied file name into a readable yet object-key-safe label:
// the extension is dropped, path separators and leading dots can never leak, whitespace collapses
// to a single underscore, and the result is length-capped. Falls back to "pet" when nothing remains.
func petImageFileLabel(name string) string {
	base := filepath.Base(name)
	if ext := filepath.Ext(base); ext != "" {
		base = strings.TrimSuffix(base, ext)
	}
	var sb strings.Builder
	pendingSpace := false
	for _, r := range base {
		if unicode.IsSpace(r) {
			pendingSpace = true
			continue
		}
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			continue
		}
		if pendingSpace && sb.Len() > 0 {
			sb.WriteRune('_')
		}
		pendingSpace = false
		sb.WriteRune(r)
	}
	label := sb.String()
	if label == "" {
		return "pet"
	}
	if runes := []rune(label); len(runes) > 40 {
		label = string(runes[:40])
	}
	return label
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
func storagePath(root, name string) string { return filepath.Join(root, name+".json") }

// petCodeQuota is the lifetime generation ledger for one activation code, summed across every
// device bound to it. Counting by code (not device) stops resets from re-binding or reinstalling.
type petCodeQuota struct {
	Used int `json:"used"`
}

// SetImageQuotaResolver wires the per-code limit lookup (backed by the activation store). Once set,
// every admission and remaining-count check uses the code's own configured total instead of the
// static default, so "no times by default" is enforced for codes that were never granted a quota.
func (s *PetImageService) SetImageQuotaResolver(fn func(code string) int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.quotaFor = fn
}

// limitForCode returns the effective lifetime image-generation limit for a code: the resolver's
// per-code value when wired, otherwise the static codeQuota field (tests / unwired fallback).
func (s *PetImageService) limitForCode(code string) int {
	if s.quotaFor != nil {
		return s.quotaFor(code)
	}
	return s.codeQuota
}
func codeQuotaKey(code string) string {
	sum := sha256.Sum256([]byte(normalizeCode(code)))
	return "quota-" + hex.EncodeToString(sum[:])
}
func (s *PetImageService) loadQuota(code string) (petCodeQuota, error) {
	var quota petCodeQuota
	data, err := os.ReadFile(storagePath(s.root, codeQuotaKey(code)))
	if os.IsNotExist(err) {
		return quota, nil
	}
	if err != nil {
		return quota, err
	}
	err = json.Unmarshal(data, &quota)
	return quota, err
}
func (s *PetImageService) saveQuota(code string, quota petCodeQuota) error {
	data, err := json.Marshal(quota)
	if err != nil {
		return err
	}
	return storage.AtomicPetWrite(storagePath(s.root, codeQuotaKey(code)), data)
}

// withQuota annotates a library with the code's remaining budget for client display. It is set on
// the returned value only, never persisted into the per-device history file.
func (s *PetImageService) withQuota(lib PetImageLibrary, code string) PetImageLibrary {
	quota, err := s.loadQuota(code)
	if err != nil {
		return lib
	}
	limit := s.limitForCode(code)
	remaining := limit - quota.Used
	if remaining < 0 {
		remaining = 0
	}
	lib.GenerationLimit = limit
	lib.GenerationRemaining = remaining
	return lib
}
// petAllStates are the four states generated together when the client uploads with "all".
// The legacy "warn" state was merged into "focus" and is no longer accepted for new uploads.
var petAllStates = []string{"focus", "idel", "sleep", "pet"}

// petOutputContentType reflects the generation pipeline that actually runs.
func petOutputContentType() string {
	if petFrameModeAnimated {
		return "image/gif"
	}
	return "image/png"
}

// petValidateGenerated accepts the output according to the active frame mode: a multi-frame GIF when
// animation is enabled, otherwise any decodable single-frame image (the transparent portrait PNG).
func petValidateGenerated(output []byte) error {
	if petFrameModeAnimated {
		animation, err := gif.DecodeAll(bytes.NewReader(output))
		if err != nil {
			return err
		}
		if len(animation.Image) < 2 {
			return errors.New("生成结果不是多帧 GIF")
		}
		return nil
	}
	if _, _, err := image.Decode(bytes.NewReader(output)); err != nil {
		return errors.New("生成结果不是有效图片")
	}
	return nil
}
func (s *PetImageService) List(device, code string) (PetImageLibrary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	lib, err := s.load(device)
	return s.withQuota(lib, code), err
}
func (s *PetImageService) Upload(device, code, name string, data []byte, states ...string) (PetImageLibrary, error) {
	all := len(states) > 0 && states[0] == "all"
	state := ""
	if !all {
		var err error
		if state, err = petTargetState(states); err != nil {
			return PetImageLibrary{}, err
		}
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
	// One upload — whether a single state or the whole set — charges a single quota unit and holds one slot.
	if err = s.admit(&lib, code); err != nil {
		return lib, err
	}
	targetStates := []string{state}
	if all {
		targetStates = petAllStates
	}
	var source [4]byte
	if _, err = rand.Read(source[:]); err != nil {
		<-s.slots
		return lib, err
	}
	// Object names lead with a sanitized file-name label so files under pet-images/objects are
	// human-readable; the random suffix keeps them unique and the label never comes from the key.
	label := petImageFileLabel(name)
	sourceID := label + "-original-" + hex.EncodeToString(source[:])
	key := deviceImageKey(device)
	if err = s.objects.Put(key+"/"+sourceID, data); err != nil {
		<-s.slots
		return lib, err
	}
	createdAt := time.Now().UTC()
	displayName := filepath.Base(name)
	batch := make([]PetImage, 0, len(targetStates))
	for _, st := range targetStates {
		var id [4]byte
		if _, err = rand.Read(id[:]); err != nil {
			_ = s.objects.Delete(key + "/" + sourceID)
			<-s.slots
			return lib, err
		}
		batch = append(batch, PetImage{ID: label + "-" + hex.EncodeToString(id[:]), SourceID: sourceID, Name: displayName, CreatedAt: createdAt, ContentType: petOutputContentType(), Status: "beautifying", PromptVersion: PetPromptVersion, SelectionVersion: lib.selectionVersion(st), State: st})
	}
	for _, item := range batch {
		lib.Images = append([]PetImage{item}, lib.Images...)
	}
	if err = s.save(device, lib); err != nil {
		_ = s.objects.Delete(key + "/" + sourceID)
		<-s.slots
		return PetImageLibrary{}, err
	}
	if all {
		s.launchBatch(key, batch)
	} else {
		s.launch(key, batch[0])
	}
	return s.withQuota(lib, code), nil
}

var ErrPetGenerationDisabled = errors.New("服务端尚未配置 OPENROUTER_API_KEY，无法生成宠物动画")
var ErrPetGenerationBusy = errors.New("生成任务繁忙，请稍后重试")
var ErrPetQuotaExhausted = errors.New("该激活码的 AI 生成次数已用完")

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
func (s *PetImageService) admit(lib *PetImageLibrary, code string) error {
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
	// Lifetime quota is charged at submit time; a later generation failure is not refunded, so a
	// code can never spend more than its configured total even with retries.
	quota, err := s.loadQuota(code)
	if err != nil {
		return err
	}
	limit := s.limitForCode(code)
	if quota.Used >= limit {
		return fmt.Errorf("该激活码累计已生成 %d 次，已达上限 %d 次：%w", quota.Used, limit, ErrPetQuotaExhausted)
	}
	select {
	case s.slots <- struct{}{}:
		quota.Used++
		if err := s.saveQuota(code, quota); err != nil {
			<-s.slots
			return err
		}
		return nil
	default:
		return ErrPetGenerationBusy
	}
}
func (s *PetImageService) Retry(device, code, id string, states ...string) (PetImageLibrary, error) {
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
		if err = s.admit(&lib, code); err != nil {
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
		return s.withQuota(lib, code), nil
	}
	return lib, os.ErrNotExist
}
// runOne generates a single image and persists its result. Slot acquisition/release and worker
// accounting are the caller's responsibility. Validation follows the active frame mode: a
// multi-frame GIF when animation is enabled, otherwise any decodable single-frame image.
func (s *PetImageService) runOne(key string, item PetImage, generator PetImageGenerator) {
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
		output, err = generator.Generate(ctx, source, item.State, progress)
	}
	if err == nil {
		err = petValidateGenerated(output)
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
}
func (s *PetImageService) launch(key string, item PetImage) {
	generator := s.generator
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		defer func() { <-s.slots }()
		s.runOne(key, item, generator)
	}()
}

// launchBatch generates every queued item sequentially inside a single worker, so one "all" upload
// holds exactly one slot and charges one quota unit. A per-state failure is recorded on that item
// and never aborts the remaining states.
func (s *PetImageService) launchBatch(key string, batch []PetImage) {
	generator := s.generator
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		defer func() { <-s.slots }()
		for _, item := range batch {
			s.runOne(key, item, generator)
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
	case "focus", "idel", "sleep", "pet":
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
