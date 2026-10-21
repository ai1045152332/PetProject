package service

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"petserver/internal/storage"
)

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
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, func(string)) ([]byte, error) { return testPetGIF(t), nil }))
	t.Cleanup(svc.Close)
	return svc
}
func TestPetImagesHistoryRestartAndIsolation(t *testing.T) {
	dir := t.TempDir()
	svc := newImageTestService(t, dir)
	original := testImage(t, "png")
	first, err := svc.Upload("device-A", "cat.png", original)
	if err != nil {
		t.Fatal(err)
	}
	firstID := first.Images[0].ID
	first = awaitPet(t, svc, "device-A", firstID)
	if first.CurrentID != firstID {
		t.Fatal("generated pet not automatically selected")
	}
	second, err := svc.Upload("device-A", "dog.jpg", testImage(t, "jpeg"))
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
	restored, err := svc.List("device-A")
	if err != nil || restored.CurrentID != firstID || len(restored.Images) != 2 {
		t.Fatalf("restore: %+v %v", restored, err)
	}
	data, mime, err := svc.Read("device-A", firstID)
	if err != nil || mime != "image/gif" {
		t.Fatal("generated GIF unavailable")
	}
	animation, err := gif.DecodeAll(bytes.NewReader(data))
	if err != nil || len(animation.Image) != 2 {
		t.Fatal("GIF frames lost")
	}
	for _, item := range restored.Images {
		if item.ID == firstID {
			raw, err := svc.objects.Get(deviceImageKey("device-A") + "/" + item.SourceID)
			if err != nil || !bytes.Equal(raw, original) {
				t.Fatal("original upload must be preserved")
			}
		}
	}
	other, err := svc.List("device-B")
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
		if _, err := svc.Upload("device", "bad.png", data); err == nil {
			t.Fatal("invalid upload accepted")
		}
	}
	lib, err := svc.List("device")
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
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, func(string)) ([]byte, error) { return nil, nil }))
	defer svc.Close()
	if _, err = svc.Upload("device", "cat.png", testImage(t, "png")); err == nil {
		t.Fatal("storage failure ignored")
	}
	lib, err := svc.List("device")
	if err != nil || lib.CurrentID != "" || len(lib.Images) != 0 {
		t.Fatal("failed upload persisted")
	}
}

type testPetGenerator func(context.Context, []byte, func(string)) ([]byte, error)

func (f testPetGenerator) Generate(ctx context.Context, b []byte, p func(string)) ([]byte, error) {
	return f(ctx, b, p)
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
		lib, err := svc.List(device)
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
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, func(string)) ([]byte, error) { return nil, fmt.Errorf("model failed") }))
	lib, err := svc.Upload("A", "cat.png", testImage(t, "png"))
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
	svc.SetGenerator(testPetGenerator(func(ctx context.Context, _ []byte, p func(string)) ([]byte, error) {
		p("animating")
		select {
		case <-release:
			return testPetGIF(t), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}))
	lib, err = svc.Retry("A", id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = svc.Upload("A", "again.png", testImage(t, "png")); err != ErrPetGenerationBusy {
		t.Fatal("duplicate in-flight generation admitted")
	}
	if _, err = svc.Retry("B", id); !os.IsNotExist(err) {
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
	if _, err := svc.Upload("A", "cat.png", testImage(t, "png")); err != ErrPetGenerationDisabled {
		t.Fatal("unconfigured generation must fail")
	}
	source := "11111111111111111111111111111111"
	if err := svc.save("A", PetImageLibrary{Images: []PetImage{{ID: source, SourceID: source, Status: "animating"}}}); err != nil {
		t.Fatal(err)
	}
	restored := newImageTestService(t, dir)
	lib, err := restored.List("A")
	if err != nil || lib.Images[0].Status != "failed" || lib.Images[0].SourceID != source {
		t.Fatal("restart must preserve original and allow explicit retry")
	}
}

func TestPetImagesSelectAndResetOnlyTheirState(t *testing.T) {
	dir := t.TempDir()
	svc := newImageTestService(t, dir)
	focus, err := svc.Upload("A", "focus.png", testImage(t, "png"), "focus")
	if err != nil {
		t.Fatal(err)
	}
	focusID := focus.Images[0].ID
	lib := awaitPet(t, svc, "A", focusID)
	if lib.selectedID("focus") != focusID || lib.selectedID("sleep") != "" {
		t.Fatal("focus generation changed another state")
	}
	sleep, err := svc.Upload("A", "sleep.png", testImage(t, "png"), "sleep")
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
	lib, err = svc.List("A")
	if err != nil || lib.selectedID("focus") != "" || lib.selectedID("sleep") != sleepID {
		t.Fatal("state selections/reset did not survive restart")
	}
	if _, err = svc.Select("A", focusID, "focus"); err != nil {
		t.Fatal(err)
	}
	if _, err = svc.Upload("A", "cat.png", testImage(t, "png"), "../../focus"); err == nil {
		t.Fatal("invalid state accepted")
	}
}
func TestPetStateGenerationRespectsOnlyTargetStateSelection(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	release := make(chan struct{})
	svc.SetGenerator(testPetGenerator(func(ctx context.Context, _ []byte, _ func(string)) ([]byte, error) {
		select {
		case <-release:
			return testPetGIF(t), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}))
	lib, err := svc.Upload("A", "cat.png", testImage(t, "png"), "sleep")
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
	legacy, err := svc.Upload("A", "old.png", testImage(t, "png"))
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
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, func(string)) ([]byte, error) { return nil, fmt.Errorf("failed") }))
	failed, err := svc.Upload("A", "bad.png", testImage(t, "png"), "warn")
	if err != nil {
		t.Fatal(err)
	}
	id := failed.Images[0].ID
	_ = awaitPet(t, svc, "A", id)
	if _, err = svc.Retry("A", id, "pet"); err == nil {
		t.Fatal("cross-state retry accepted")
	}
	svc.SetGenerator(testPetGenerator(func(context.Context, []byte, func(string)) ([]byte, error) { return testPetGIF(t), nil }))
	if _, err = svc.Retry("A", id, "warn"); err != nil {
		t.Fatal(err)
	}
	lib = awaitPet(t, svc, "A", id)
	if lib.selectedID("warn") != id || lib.selectedID("focus") != "" || lib.selectedID("sleep") != legacyID {
		t.Fatal("retry changed another state")
	}
}
