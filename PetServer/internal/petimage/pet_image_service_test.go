package petimage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"petserver/internal/storage"
)

// A single activation code is shared by every quota-consuming call in these tests; the per-code
// ledger lives in each test's own temp directory, so instances never bleed across tests.
const petTestCode = "AAAA-BBBB-CCCC"

func testImage(t *testing.T, format string) []byte {
	t.Helper()
	im := image.NewNRGBA(image.Rect(0, 0, 20, 10))
	im.SetNRGBA(2, 2, color.NRGBA{R: 255, A: 80})
	var b bytes.Buffer
	var err error
	if format == "png" {
		err = png.Encode(&b, im)
	} else {
		err = jpeg.Encode(&b, im, nil)
	}
	if err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func newImageTestService(t *testing.T, dir string) *PetImageService {
	t.Helper()
	objects, err := storage.NewLocalPetImageObjects(filepath.Join(dir, "objects"))
	if err != nil {
		t.Fatal(err)
	}
	svc, err := NewPetImageService(filepath.Join(dir, "libraries"), objects)
	if err != nil {
		t.Fatal(err)
	}
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, string, func(string)) ([]byte, error) { return testPetGIF(t), nil }))
	// Codes are ungranted by default (0); grant a generous static budget so only the quota-focused
	// tests exercise the limit, and they override this value explicitly.
	svc.codeQuota = 100
	t.Cleanup(svc.Close)
	return svc
}
func TestPetImagesHistoryRestartAndIsolation(t *testing.T) {
	dir := t.TempDir()
	svc := newImageTestService(t, dir)
	original := testImage(t, "png")
	first, err := svc.Upload("device-A", petTestCode, "cat.png", original)
	if err != nil {
		t.Fatal(err)
	}
	firstID := first.Images[0].ID
	first = awaitPet(t, svc, "device-A", firstID)
	if first.CurrentID != firstID {
		t.Fatal("generated pet not automatically selected")
	}
	second, err := svc.Upload("device-A", petTestCode, "dog.jpg", testImage(t, "jpeg"))
	if err != nil {
		t.Fatal(err)
	}
	second = awaitPet(t, svc, "device-A", second.Images[0].ID)
	if len(second.Images) != 2 || second.CurrentID == firstID {
		t.Fatal("history or selection lost")
	}
	if _, err = svc.Select("device-A", firstID); err != nil {
		t.Fatal(err)
	}
	// Fresh service instance simulates server restart and a client reinstall with the same hardware ID.
	svc = newImageTestService(t, dir)
	restored, err := svc.List("device-A", petTestCode)
	if err != nil || restored.CurrentID != firstID || len(restored.Images) != 2 {
		t.Fatalf("restore: %+v %v", restored, err)
	}
	data, mime, err := svc.Read("device-A", firstID)
	if err != nil || mime != petOutputContentType() {
		t.Fatal("generated image unavailable")
	}
	if petFrameModeAnimated {
		if animation, decErr := gif.DecodeAll(bytes.NewReader(data)); decErr != nil || len(animation.Image) != 2 {
			t.Fatal("GIF frames lost")
		}
	} else if _, _, decErr := image.Decode(bytes.NewReader(data)); decErr != nil {
		t.Fatal("generated image is not decodable")
	}
	for _, item := range restored.Images {
		if item.ID == firstID {
			raw, err := svc.objects.Get(deviceImageKey("device-A") + "/" + item.SourceID)
			if err != nil || !bytes.Equal(raw, original) {
				t.Fatal("original upload must be preserved")
			}
		}
	}
	other, err := svc.List("device-B", petTestCode)
	if err != nil || len(other.Images) != 0 {
		t.Fatal("device history leaked")
	}
	if _, _, err = svc.Read("device-B", firstID); !os.IsNotExist(err) {
		t.Fatal("cross-device read permitted")
	}
	if _, err = svc.Select("device-B", firstID); !os.IsNotExist(err) {
		t.Fatal("cross-device selection permitted")
	}
	reset, err := svc.Select("device-A", "")
	if err != nil || reset.CurrentID != "" || len(reset.Images) != 2 {
		t.Fatal("reset must preserve history")
	}
}
func TestPetImagesRejectInvalidInput(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	valid := testImage(t, "png")
	for _, data := range [][]byte{nil, []byte("not an image"), append([]byte("GIF89a"), make([]byte, 100)...), make([]byte, MaxPetImageBytes+1), valid[:len(valid)/2]} {
		if _, err := svc.Upload("device", petTestCode, "bad.png", data); err == nil {
			t.Fatal("invalid upload accepted")
		}
	}
	lib, err := svc.List("device", petTestCode)
	if err != nil || len(lib.Images) != 0 {
		t.Fatal("failed upload changed history")
	}
}

type failingPetObjects struct{}

func (failingPetObjects) Put(string, []byte) error   { return os.ErrPermission }
func (failingPetObjects) Get(string) ([]byte, error) { return nil, os.ErrPermission }
func (failingPetObjects) Delete(string) error        { return nil }
func TestPetImagesStorageFailureDoesNotSelect(t *testing.T) {
	svc, err := NewPetImageService(t.TempDir(), failingPetObjects{})
	if err != nil {
		t.Fatal(err)
	}
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, string, func(string)) ([]byte, error) { return nil, nil }))
	defer svc.Close()
	if _, err = svc.Upload("device", petTestCode, "cat.png", testImage(t, "png")); err == nil {
		t.Fatal("storage failure ignored")
	}
	lib, err := svc.List("device", petTestCode)
	if err != nil || lib.CurrentID != "" || len(lib.Images) != 0 {
		t.Fatal("failed upload persisted")
	}
}

type testPetGenerator func(context.Context, []byte, string, func(string)) ([]byte, error)

func (f testPetGenerator) Generate(ctx context.Context, b []byte, state string, p func(string)) ([]byte, error) {
	return f(ctx, b, state, p)
}
func testPetGIF(t *testing.T) []byte {
	t.Helper()
	pal := color.Palette{color.Transparent, color.White}
	a := image.NewPaletted(image.Rect(0, 0, 20, 20), pal)
	a.SetColorIndex(5, 5, 1)
	b := image.NewPaletted(a.Rect, pal)
	b.SetColorIndex(6, 5, 1)
	var data bytes.Buffer
	if err := gif.EncodeAll(&data, &gif.GIF{Image: []*image.Paletted{a, b}, Delay: []int{10, 10}, LoopCount: 0}); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}
func awaitPet(t *testing.T, svc *PetImageService, device, id string) PetImageLibrary {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		lib, err := svc.List(device, petTestCode)
		if err != nil {
			t.Fatal(err)
		}
		for _, item := range lib.Images {
			if item.ID == id && !petGenerating(item.Status) {
				return lib
			}
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("generation did not finish")
	return PetImageLibrary{}
}
func TestPetGenerationFailureRetryAndManualSelection(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, string, func(string)) ([]byte, error) {
		return nil, fmt.Errorf("model failed")
	}))
	lib, err := svc.Upload("A", petTestCode, "cat.png", testImage(t, "png"))
	if err != nil {
		t.Fatal(err)
	}
	id := lib.Images[0].ID
	lib = awaitPet(t, svc, "A", id)
	if lib.CurrentID != "" || lib.Images[0].Status != "failed" {
		t.Fatal("failed generation replaced pet")
	}
	if _, _, err = svc.Read("A", id); !os.IsNotExist(err) {
		t.Fatal("failed result downloadable")
	}
	if _, err = svc.Select("A", id); !os.IsNotExist(err) {
		t.Fatal("failed result selectable")
	}
	release := make(chan struct{})
	svc.SetGenerator(testPetGenerator(func(ctx context.Context, _ []byte, _ string, p func(string)) ([]byte, error) {
		p("animating")
		select {
		case <-release:
			return testPetGIF(t), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}))
	lib, err = svc.Retry("A", petTestCode, id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = svc.Upload("A", petTestCode, "again.png", testImage(t, "png")); err != ErrPetGenerationBusy {
		t.Fatal("duplicate in-flight generation admitted")
	}
	if _, err = svc.Retry("B", petTestCode, id); !os.IsNotExist(err) {
		t.Fatal("cross-device retry allowed")
	}
	if _, err = svc.Select("A", ""); err != nil {
		t.Fatal(err)
	}
	close(release)
	lib = awaitPet(t, svc, "A", id)
	if lib.Images[0].Status != "ready" || lib.CurrentID != "" {
		t.Fatal("generation overwrote explicit reset")
	}
}
func TestPetGenerationMissingConfigurationAndRestart(t *testing.T) {
	dir := t.TempDir()
	svc := newImageTestService(t, dir)
	svc.SetGenerator(nil)
	if _, err := svc.Upload("A", petTestCode, "cat.png", testImage(t, "png")); err != ErrPetGenerationDisabled {
		t.Fatal("unconfigured generation must fail")
	}
	source := "11111111111111111111111111111111"
	if err := svc.save("A", PetImageLibrary{Images: []PetImage{{ID: source, SourceID: source, Status: "animating"}}}); err != nil {
		t.Fatal(err)
	}
	restored := newImageTestService(t, dir)
	lib, err := restored.List("A", petTestCode)
	if err != nil || lib.Images[0].Status != "failed" || lib.Images[0].SourceID != source {
		t.Fatal("restart must preserve original and allow explicit retry")
	}
}

func TestPetImagesSelectAndResetOnlyTheirState(t *testing.T) {
	dir := t.TempDir()
	svc := newImageTestService(t, dir)
	focus, err := svc.Upload("A", petTestCode, "focus.png", testImage(t, "png"), "focus")
	if err != nil {
		t.Fatal(err)
	}
	focusID := focus.Images[0].ID
	lib := awaitPet(t, svc, "A", focusID)
	if lib.selectedID("focus") != focusID || lib.selectedID("sleep") != "" {
		t.Fatal("focus generation changed another state")
	}
	sleep, err := svc.Upload("A", petTestCode, "sleep.png", testImage(t, "png"), "sleep")
	if err != nil {
		t.Fatal(err)
	}
	sleepID := sleep.Images[0].ID
	lib = awaitPet(t, svc, "A", sleepID)
	if lib.selectedID("focus") != focusID || lib.selectedID("sleep") != sleepID {
		t.Fatal("sleep generation overwrote focus")
	}
	if _, err = svc.Select("A", focusID, "sleep"); !os.IsNotExist(err) {
		t.Fatal("state-specific image selected for different state")
	}
	if _, err = svc.Select("A", "", "focus"); err != nil {
		t.Fatal(err)
	}
	svc = newImageTestService(t, dir)
	lib, err = svc.List("A", petTestCode)
	if err != nil || lib.selectedID("focus") != "" || lib.selectedID("sleep") != sleepID {
		t.Fatal("state selections/reset did not survive restart")
	}
	if _, err = svc.Select("A", focusID, "focus"); err != nil {
		t.Fatal(err)
	}
	if _, err = svc.Upload("A", petTestCode, "cat.png", testImage(t, "png"), "../../focus"); err == nil {
		t.Fatal("invalid state accepted")
	}
	// The legacy "warn" state was merged into "focus" and must no longer be accepted for uploads.
	if _, err = svc.Upload("A", petTestCode, "cat.png", testImage(t, "png"), "warn"); err == nil {
		t.Fatal("removed legacy warn state accepted")
	}
}
func TestPetStateGenerationRespectsOnlyTargetStateSelection(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	release := make(chan struct{})
	svc.SetGenerator(testPetGenerator(func(ctx context.Context, _ []byte, _ string, _ func(string)) ([]byte, error) {
		select {
		case <-release:
			return testPetGIF(t), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}))
	lib, err := svc.Upload("A", petTestCode, "cat.png", testImage(t, "png"), "sleep")
	if err != nil {
		t.Fatal(err)
	}
	id := lib.Images[0].ID
	if _, err = svc.Select("A", "", "focus"); err != nil {
		t.Fatal(err)
	}
	close(release)
	lib = awaitPet(t, svc, "A", id)
	if lib.selectedID("sleep") != id || lib.selectedID("focus") != "" {
		t.Fatal("unrelated state reset interfered with generation")
	}
}
func TestPetStateRetryAndLegacySharedImage(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	legacy, err := svc.Upload("A", petTestCode, "old.png", testImage(t, "png"))
	if err != nil {
		t.Fatal(err)
	}
	legacyID := legacy.Images[0].ID
	lib := awaitPet(t, svc, "A", legacyID)
	if lib.selectedID("focus") != legacyID || lib.selectedID("sleep") != legacyID {
		t.Fatal("legacy shared image not restored")
	}
	lib, err = svc.Select("A", "", "focus")
	if err != nil {
		t.Fatal(err)
	}
	if lib.selectedID("focus") != "" || lib.selectedID("sleep") != legacyID {
		t.Fatal("reset fell back to legacy shared image")
	}
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, string, func(string)) ([]byte, error) { return nil, fmt.Errorf("failed") }))
	failed, err := svc.Upload("A", petTestCode, "bad.png", testImage(t, "png"), "idel")
	if err != nil {
		t.Fatal(err)
	}
	id := failed.Images[0].ID
	_ = awaitPet(t, svc, "A", id)
	if _, err = svc.Retry("A", petTestCode, id, "pet"); err == nil {
		t.Fatal("cross-state retry accepted")
	}
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, string, func(string)) ([]byte, error) { return testPetGIF(t), nil }))
	if _, err = svc.Retry("A", petTestCode, id, "idel"); err != nil {
		t.Fatal(err)
	}
	lib = awaitPet(t, svc, "A", id)
	if lib.selectedID("idel") != id || lib.selectedID("focus") != "" || lib.selectedID("sleep") != legacyID {
		t.Fatal("retry changed another state")
	}
}

// The stored image name must stay readable yet safe: it is derived from a client-supplied file
// name, so path separators and leading dots can never leak into an object key.
func TestPetImageFileLabel(t *testing.T) {
	cases := map[string]string{
		"cat.png":            "cat",
		"my cat!!!":          "my_cat",
		"../../etc/passwd":   "passwd",
		"..hidden.png":       "hidden",
		"  weird name  .jpg": "weird_name",
		"!!!!.png":           "pet",
		"...":                "pet",
	}
	for name, want := range cases {
		if got := petImageFileLabel(name); got != want {
			t.Fatalf("petImageFileLabel(%q) = %q, want %q", name, got, want)
		}
	}
	// CJK and long names: readable stem preserved, never contains '/' or leading '.', capped.
	if got := petImageFileLabel("\u6211\u7684\u5ba0\u7269.jpeg"); got != "\u6211\u7684\u5ba0\u7269" {
		t.Fatalf("CJK label = %q", got)
	}
	long := petImageFileLabel(string(bytes.Repeat([]byte("a"), 200)) + ".png")
	if len([]rune(long)) > 24 || strings.ContainsAny(long, "/") || strings.HasPrefix(long, ".") {
		t.Fatalf("long label unsafe: %q", long)
	}
	// One upload = one folder under the device key: the original photo and every generated state
	// share a batch folder instead of piling up flat in the device directory.
	svc := newImageTestService(t, t.TempDir())
	uploaded, err := svc.Upload("device-A", petTestCode, "my cat!!!.png", testImage(t, "png"))
	if err != nil {
		t.Fatal(err)
	}
	item := uploaded.Images[0]
	awaitPet(t, svc, "device-A", item.ID)
	// The client-visible ID stays a bare 32-hex cache key (CustomSpriteStore.validID).
	if len(item.ID) != 32 || strings.Trim(item.ID, "0123456789abcdef") != "" {
		t.Fatalf("id is not 32-hex: %q", item.ID)
	}
	batch, sourceName, split := strings.Cut(item.SourceID, "/")
	if !split || len(batch) != 22 || batch[8] != '-' || batch[15] != '-' {
		t.Fatalf("source not inside an upload folder: %q", item.SourceID)
	}
	if sourceName != "original-my_cat.png" {
		t.Fatalf("source name = %q", sourceName)
	}
	if item.ObjectID != batch+"/shared-my_cat.png" {
		t.Fatalf("result not in the same folder as its source: %q", item.ObjectID)
	}
	for _, id := range []string{item.SourceID, item.ObjectID} {
		if _, err = svc.objects.Get(deviceImageKey("device-A") + "/" + id); err != nil {
			t.Fatalf("object %q missing after upload: %v", id, err)
		}
	}
	if result, _, err := svc.Read("device-A", item.ID); err != nil || len(result) == 0 {
		t.Fatalf("batched result not readable: %v", err)
	}
	// Both the batch layout and the older flat layout must pass the storage validator.
	objects, err := storage.NewLocalPetImageObjects(filepath.Join(t.TempDir(), "objects"))
	if err != nil {
		t.Fatal(err)
	}
	deviceKey := deviceImageKey("device-A")
	batchKey := "20261026-151149-1a2b3c"
	for _, id := range []string{
		deviceKey + "/" + batchKey + "/original-cat.png",
		deviceKey + "/" + batchKey + "/focus-cat.png",
		deviceKey + "/legacy-cat-1a2b3c4d",
	} {
		if err = objects.Put(id, []byte("x")); err != nil {
			t.Fatalf("object key %q rejected: %v", id, err)
		}
	}
	for _, bad := range []string{
		deviceKey + "/../escape",
		deviceKey + "/" + batchKey + "/../escape",
		deviceKey + "/notabatch/escape.png",
		deviceKey + "/" + batchKey + "/.hidden",
	} {
		if err = objects.Put(bad, []byte("x")); err == nil {
			t.Fatalf("unsafe object key accepted: %q", bad)
		}
	}
}

// The per-code quota is a lifetime total shared across every device bound to the code, and it
// survives a restart because the ledger lives in the shared library directory, not per device.
func TestPetImageCodeQuotaIsLifetimeAcrossDevices(t *testing.T) {
	dir := t.TempDir()
	svc := newImageTestService(t, dir)
	svc.codeQuota = 2
	first, err := svc.Upload("device-A", petTestCode, "a.png", testImage(t, "png"))
	if err != nil {
		t.Fatal(err)
	}
	_ = awaitPet(t, svc, "device-A", first.Images[0].ID)
	second, err := svc.Upload("device-B", petTestCode, "b.png", testImage(t, "png"))
	if err != nil {
		t.Fatal(err)
	}
	second = awaitPet(t, svc, "device-B", second.Images[0].ID)
	if second.GenerationLimit != 2 || second.GenerationRemaining != 0 {
		t.Fatalf("remaining after two generations = %d/%d, want 0/2", second.GenerationRemaining, second.GenerationLimit)
	}
	if _, err = svc.Upload("device-C", petTestCode, "c.png", testImage(t, "png")); !errors.Is(err, ErrPetQuotaExhausted) {
		t.Fatalf("quota not enforced on a new device for the same code: %v", err)
	}
	// A fresh service over the same directory still sees the lifetime usage for that code.
	svc = newImageTestService(t, dir)
	svc.codeQuota = 2
	if lib, err := svc.List("device-A", petTestCode); err != nil || lib.GenerationRemaining != 0 {
		t.Fatalf("lifetime usage lost after restart: %+v %v", lib, err)
	}
	if _, err = svc.Upload("device-D", petTestCode, "d.png", testImage(t, "png")); !errors.Is(err, ErrPetQuotaExhausted) {
		t.Fatal("restart reset the lifetime quota")
	}
	// A different activation code keeps its own independent budget.
	other, err := svc.Upload("device-E", "ZZZZ-YYYY-XXXX", "e.png", testImage(t, "png"))
	if err != nil {
		t.Fatalf("unrelated code should not share the exhausted budget: %v", err)
	}
	if other.GenerationRemaining != 1 {
		t.Fatalf("fresh code remaining = %d, want 1", other.GenerationRemaining)
	}
}

// The service resolves the per-code lifetime limit through the wired resolver, so a code that was
// never granted a quota (default 0) cannot generate, and an admin grant/revoke takes effect live.
func TestPetImageQuotaResolverEnforcesPerCodeDefaultZero(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	limits := map[string]int{petTestCode: 0}
	svc.SetImageQuotaResolver(func(code string) int { return limits[code] })
	// The resolver wins over the static fallback: a zero-quota code is blocked even with codeQuota=100.
	svc.codeQuota = 100
	if _, err := svc.Upload("device-A", petTestCode, "cat.png", testImage(t, "png")); !errors.Is(err, ErrPetQuotaExhausted) {
		t.Fatalf("code with zero resolver quota should be blocked, got %v", err)
	}
	// Granting two units through the (admin-backed) resolver unlocks exactly two generations.
	limits[petTestCode] = 2
	first, err := svc.Upload("device-A", petTestCode, "cat.png", testImage(t, "png"))
	if err != nil {
		t.Fatal(err)
	}
	awaitPet(t, svc, "device-A", first.Images[0].ID)
	if lib, err := svc.List("device-A", petTestCode); err != nil || lib.GenerationLimit != 2 || lib.GenerationRemaining != 1 {
		t.Fatalf("after grant limit/remaining = %+v %v", lib, err)
	}
	// Revoking below the used count floors remaining at zero and blocks the next submit.
	limits[petTestCode] = 0
	if lib, err := svc.List("device-A", petTestCode); err != nil || lib.GenerationRemaining != 0 {
		t.Fatalf("revoked code should show 0 remaining: %+v %v", lib, err)
	}
	if _, err := svc.Upload("device-A", petTestCode, "b.png", testImage(t, "png")); !errors.Is(err, ErrPetQuotaExhausted) {
		t.Fatalf("revoked code should be blocked, got %v", err)
	}
}

// One "all" upload fans out into exactly one record per state, charges a single quota unit, and is
// generated sequentially while holding one slot; every state ends up independently selected.
func TestPetImageUploadAllFansOutOnePerState(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	svc.codeQuota = 5
	lib, err := svc.Upload("device-A", petTestCode, "cat.png", testImage(t, "png"), "all")
	if err != nil {
		t.Fatal(err)
	}
	if len(lib.Images) != len(petAllStates) {
		t.Fatalf("all upload created %d records, want %d", len(lib.Images), len(petAllStates))
	}
	if lib.GenerationRemaining != 4 {
		t.Fatalf("batch charged %d quota units, want 1", 5-lib.GenerationRemaining)
	}
	seenStates := make(map[string]bool, len(petAllStates))
	for _, item := range lib.Images {
		if item.State == "" || seenStates[item.State] {
			t.Fatalf("duplicate or empty state in batch: %q", item.State)
		}
		seenStates[item.State] = true
	}
	for _, want := range petAllStates {
		if !seenStates[want] {
			t.Fatalf("state %s missing from batch fan-out", want)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	var finished PetImageLibrary
	for time.Now().Before(deadline) {
		finished, err = svc.List("device-A", petTestCode)
		if err != nil {
			t.Fatal(err)
		}
		generating := false
		for _, item := range finished.Images {
			if petGenerating(item.Status) {
				generating = true
			}
		}
		if !generating {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if finished.CurrentIDs == nil || len(finished.CurrentIDs) != len(petAllStates) {
		t.Fatalf("expected %d per-state selections, got %+v", len(petAllStates), finished.CurrentIDs)
	}
	for _, item := range finished.Images {
		if item.Status != "ready" {
			t.Fatalf("state %s ended in status %q", item.State, item.Status)
		}
		if finished.CurrentIDs[item.State] != item.ID {
			t.Fatalf("state %s not auto-selected", item.State)
		}
	}
}

// 单帧成品落盘前缩到 512；缩小只是优化，非 PNG、已经够小的图必须原样返回。
func TestDownscalePetPNG(t *testing.T) {
	im := image.NewNRGBA(image.Rect(0, 0, petCanvas, petCanvas))
	for y := 256; y < petCanvas; y++ {
		for x := 256; x < petCanvas; x++ {
			im.SetNRGBA(x, y, color.NRGBA{R: 255, G: 128, B: 64, A: 255})
		}
	}
	im.SetNRGBA(0, 0, color.NRGBA{R: 10, G: 20, B: 30, A: 128})
	var big bytes.Buffer
	if err := png.Encode(&big, im); err != nil {
		t.Fatal(err)
	}
	small, err := downscalePetPNG(big.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(small))
	if err != nil || format != "png" || cfg.Width != petOutputCanvas || cfg.Height != petOutputCanvas {
		t.Fatalf("downscaled output %dx%d format=%q err=%v", cfg.Width, cfg.Height, format, err)
	}
	shrunk, err := png.Decode(bytes.NewReader(small))
	if err != nil {
		t.Fatal(err)
	}
	if got := color.NRGBAModel.Convert(shrunk.At(511, 511)).(color.NRGBA); got != (color.NRGBA{R: 255, G: 128, B: 64, A: 255}) {
		t.Fatalf("opaque region = %+v", got)
	}
	// 单个半透明像素被 4 格均摊：alpha 降为 1/4，颜色经预乘均值后基本保留（允许往返量化误差）。
	if got := color.NRGBAModel.Convert(shrunk.At(0, 0)).(color.NRGBA); got.A != 32 || absDiff(int(got.R), 10) > 3 || absDiff(int(got.G), 20) > 3 || absDiff(int(got.B), 30) > 3 {
		t.Fatalf("semi-transparent corner = %+v", got)
	}
	if unchanged, err := downscalePetPNG(small); err != nil || !bytes.Equal(unchanged, small) {
		t.Fatal("512 PNG must pass through")
	}
	gifData := testPetGIF(t)
	if unchanged, err := downscalePetPNG(gifData); err != nil || !bytes.Equal(unchanged, gifData) {
		t.Fatal("gif must pass through")
	}
}

func absDiff(a, b int) int {
	if a < b {
		return b - a
	}
	return a - b
}

// 生成链路端到端：1024 成品经 runOne 缩小后才写入对象存储，历史原图不受影响。
func TestPetImagesGeneratedShrunkBeforeStore(t *testing.T) {
	if petFrameModeAnimated {
		t.Skip("动画 GIF 管线不缩小")
	}
	svc := newImageTestService(t, t.TempDir())
	im := image.NewNRGBA(image.Rect(0, 0, petCanvas, petCanvas))
	for y := 0; y < petCanvas; y++ {
		for x := petCanvas / 2; x < petCanvas; x++ {
			im.SetNRGBA(x, y, color.NRGBA{R: 200, G: 120, B: 60, A: 255})
		}
	}
	var big bytes.Buffer
	if err := png.Encode(&big, im); err != nil {
		t.Fatal(err)
	}
	source := testImage(t, "png")
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, string, func(string)) ([]byte, error) { return big.Bytes(), nil }))
	lib, err := svc.Upload("A", petTestCode, "cat.png", source)
	if err != nil {
		t.Fatal(err)
	}
	id := lib.Images[0].ID
	lib = awaitPet(t, svc, "A", id)
	if lib.Images[0].Status != "ready" {
		t.Fatalf("generation failed: %s", lib.Images[0].Error)
	}
	data, _, err := svc.Read("A", id)
	if err != nil {
		t.Fatal(err)
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || format != "png" || cfg.Width != petOutputCanvas || cfg.Height != petOutputCanvas {
		t.Fatalf("stored image %dx%d format=%q err=%v", cfg.Width, cfg.Height, format, err)
	}
	raw, err := svc.objects.Get(deviceImageKey("A") + "/" + lib.Images[0].SourceID)
	if err != nil || !bytes.Equal(raw, source) {
		t.Fatal("original photo must stay untouched")
	}
}
