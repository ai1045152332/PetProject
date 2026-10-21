package controller

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"mime/multipart"
	"net/http/httptest"
	"path/filepath"
	"petserver/internal/crypto"
	"testing"
	"time"

	"petserver/internal/model"
	"petserver/internal/service"
	"petserver/internal/storage"
)

func TestPetImageAuthorizationAndUpload(t *testing.T) {
	dir := t.TempDir()
	codes, err := storage.NewActivationStore(filepath.Join(dir, "codes.json"))
	if err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-time.Hour)
	err = codes.Save([]model.ActivationCode{
		{Code: "ABCD-EFGH-JKMP", Devices: []string{"A"}, MaxDevices: 2},
		{Code: "QRST-UVWX-YZ23", Devices: []string{"A"}, MaxDevices: 2, ExpiresAt: &past},
	})
	if err != nil {
		t.Fatal(err)
	}
	access := service.NewAccessService(codes)
	objects, _ := storage.NewLocalPetImageObjects(filepath.Join(dir, "objects"))
	svc, _ := service.NewPetImageService(filepath.Join(dir, "libraries"), objects)
	svc.SetGenerator(controllerPetGenerator{})
	t.Cleanup(svc.Close)
	ctrl := NewPetImageController(svc, access, nil)
	for _, auth := range []string{
		`{"code":"456","deviceId":"A"}`,
		`{"code":"ABCD-EFGH-JKMP","deviceId":"B"}`,
		`{"code":"QRST-UVWX-YZ23","deviceId":"A"}`,
		`{"code":"ABCD-EFGH-JKMP","deviceId":"unknown-device"}`,
	} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/api/pet-images/list", bytes.NewBufferString(auth))
		ctrl.Handle(w, r)
		if w.Code != 403 {
			t.Fatalf("auth accepted: %s status %d", auth, w.Code)
		}
	}
	auth := `{"code":"ABCD-EFGH-JKMP","deviceId":"A","state":"focus"}`
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("auth", auth)
	part, _ := writer.CreateFormFile("image", "cat.png")
	_ = png.Encode(part, image.NewNRGBA(image.Rect(0, 0, 10, 10)))
	_ = writer.Close()
	req := httptest.NewRequest("POST", "/api/pet-images/upload", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	ctrl.Handle(w, req)
	if w.Code != 200 {
		t.Fatalf("upload: %d %s", w.Code, w.Body.String())
	}
	var response struct {
		Data service.PetImageLibrary `json:"data"`
	}
	if err = json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Data.Images) != 1 || response.Data.Images[0].State != "focus" || response.Data.Images[0].Status != "beautifying" || response.Data.CurrentID != "" {
		t.Fatal("upload must return pending job without replacing the pet")
	}
	w = httptest.NewRecorder()
	ctrl.Handle(w, httptest.NewRequest("GET", "/api/pet-images/list", nil))
	if w.Code != 405 {
		t.Fatal("GET credentials must not be supported")
	}
}

// Exercise the encrypted multipart auth format used by the macOS client.
func TestPetImageEncryptedMultipart(t *testing.T) {
	dir := t.TempDir()
	key, _, err := crypto.LoadOrCreate(filepath.Join(dir, "private.pem"))
	if err != nil {
		t.Fatal(err)
	}
	codes, err := storage.NewActivationStore(filepath.Join(dir, "codes.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = codes.Save([]model.ActivationCode{{Code: "ABCD-EFGH-JKMP", Devices: []string{"A"}}}); err != nil {
		t.Fatal(err)
	}
	objects, _ := storage.NewLocalPetImageObjects(filepath.Join(dir, "objects"))
	svc, _ := service.NewPetImageService(filepath.Join(dir, "libraries"), objects)
	svc.SetGenerator(controllerPetGenerator{})
	t.Cleanup(svc.Close)
	ctrl := NewPetImageController(svc, service.NewAccessService(codes), key)
	auth := []byte(`{"code":"ABCD-EFGH-JKMP","deviceId":"A"}`)
	aesKey := make([]byte, 32)
	if _, err = rand.Read(aesKey); err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(aesKey)
	gcm, _ := cipher.NewGCM(block)
	nonce := make([]byte, gcm.NonceSize())
	_, _ = rand.Read(nonce)
	combined := gcm.Seal(nonce, nonce, auth, nil)
	wrapped, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &key.Private.PublicKey, aesKey, nil)
	if err != nil {
		t.Fatal(err)
	}
	envelope, _ := json.Marshal(map[string]string{"encryptedKey": base64.StdEncoding.EncodeToString(wrapped), "data": base64.StdEncoding.EncodeToString(combined)})
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("auth", string(envelope))
	part, _ := writer.CreateFormFile("image", "cat.png")
	_ = png.Encode(part, image.NewNRGBA(image.Rect(0, 0, 10, 10)))
	_ = writer.Close()
	req := httptest.NewRequest("POST", "/api/pet-images/upload", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	ctrl.Handle(w, req)
	if w.Code != 200 {
		t.Fatalf("encrypted upload: %d %s", w.Code, w.Body.String())
	}
}

type controllerPetGenerator struct{}

func (controllerPetGenerator) Generate(context.Context, []byte, string, func(string)) ([]byte, error) {
	pal := color.Palette{color.Transparent, color.White}
	frame := image.NewPaletted(image.Rect(0, 0, 10, 10), pal)
	var b bytes.Buffer
	err := gif.EncodeAll(&b, &gif.GIF{Image: []*image.Paletted{frame, frame}, Delay: []int{10, 10}})
	return b.Bytes(), err
}
