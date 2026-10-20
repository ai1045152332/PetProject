package service

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"

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
	firstID := first.CurrentID
	second, err := svc.Upload("device-A", "dog.jpg", testImage(t, "jpeg"))
	if err != nil {
		t.Fatal(err)
	}
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
	if err != nil || mime != "image/png" || !bytes.Equal(data, original) {
		t.Fatal("original PNG and alpha must be preserved")
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
	if _, err = svc.Upload("device", "cat.png", testImage(t, "png")); err == nil {
		t.Fatal("storage failure ignored")
	}
	lib, err := svc.List("device")
	if err != nil || lib.CurrentID != "" || len(lib.Images) != 0 {
		t.Fatal("failed upload persisted")
	}
}
