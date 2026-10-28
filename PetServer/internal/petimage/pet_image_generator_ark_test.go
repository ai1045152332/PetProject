package petimage

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// arkChromaFixture 造一张绿幕背景 + 棕色主体 + 断开绿眼睛的方图，模拟官方 4.5 的 JPEG/PNG 输出。
func arkChromaFixture(t *testing.T) []byte {
	t.Helper()
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(320, 260, 700, 820), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
	im.SetNRGBA(500, 500, color.NRGBA{G: 255, A: 255}) // 主体内断开的绿眼睛必须保留
	var b bytes.Buffer
	if err := png.Encode(&b, im); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestArkGeneratorContractAndSingleFrameChroma(t *testing.T) {
	fixture := arkChromaFixture(t)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != http.MethodPost || r.URL.Path != "/api/v3/images/generations" {
			t.Errorf("unexpected endpoint %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer ark-key" || r.Header.Get("Content-Type") != "application/json" {
			t.Error("incorrect ARK auth/content headers")
		}
		var payload map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		var model, size, respFmt, sequential, imageField string
		var prompt string
		_ = json.Unmarshal(payload["model"], &model)
		_ = json.Unmarshal(payload["size"], &size)
		_ = json.Unmarshal(payload["response_format"], &respFmt)
		_ = json.Unmarshal(payload["sequential_image_generation"], &sequential)
		_ = json.Unmarshal(payload["image"], &imageField)
		_ = json.Unmarshal(payload["prompt"], &prompt)
		if model != DefaultArkPetImageModel {
			t.Errorf("model=%q", model)
		}
		if size != "2K" || respFmt != "b64_json" || sequential != "disabled" {
			t.Errorf("size=%q response_format=%q sequential=%q", size, respFmt, sequential)
		}
		var watermark bool
		_ = json.Unmarshal(payload["watermark"], &watermark)
		if watermark {
			t.Error("watermark must be disabled")
		}
		if !strings.HasPrefix(imageField, "data:image/jpeg;base64,") {
			t.Errorf("reference image must be an inline base64 data URL, got %q", imageField[:min(32, len(imageField))])
		}
		if !strings.Contains(prompt, "#00FF00") {
			t.Error("missing chroma instructions in prompt")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(fixture)}}})
	}))
	defer server.Close()

	generator := NewArkPetImageGenerator("ark-key", "")
	generator.endpoint = server.URL + "/api/v3/images/generations"
	output, err := generator.Generate(context.Background(), testImage(t, "jpeg"), "sleep", func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	if petFrameModeAnimated {
		t.Skip("animated GIF path covered by OpenRouter contract test")
	}
	if calls != 1 {
		t.Fatalf("single-frame ARK made %d requests, want 1", calls)
	}
	portrait, err := png.Decode(bytes.NewReader(output))
	if err != nil {
		t.Fatal("single-frame ARK output is not a PNG", err)
	}
	if _, _, _, a := portrait.At(0, 0).RGBA(); a != 0 {
		t.Fatal("green background remains opaque")
	}
	if _, _, _, a := portrait.At(500, 500).RGBA(); a == 0 {
		t.Fatal("green eye removed with background")
	}
}

func TestArkGeneratorDownloadsURLFallback(t *testing.T) {
	fixture := arkChromaFixture(t)
	var srv *httptest.Server
	imageServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(fixture)
	}))
	defer imageServer.Close()
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload map[string]json.RawMessage
		_ = json.NewDecoder(r.Body).Decode(&payload)
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]any{{"url": imageServer.URL}}})
	}))
	defer srv.Close()

	generator := NewArkPetImageGenerator("ark-key", "custom-model")
	generator.endpoint = srv.URL
	if generator.Model() != "custom-model" {
		t.Fatalf("model override lost: %q", generator.Model())
	}
	output, err := generator.Generate(context.Background(), testImage(t, "png"), "idel", func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = png.Decode(bytes.NewReader(output)); err != nil {
		t.Fatal("URL-fallback output not a PNG", err)
	}
}

func TestArkGeneratorFailuresAreSafe(t *testing.T) {
	if NewArkPetImageGenerator("", "") != nil {
		t.Fatal("missing API key should disable generation")
	}
	for _, status := range []int{400, 401, 403, 404, 429, 500, 200} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"error":{"code":"InternalServiceError","message":"secret-key"}}`))
		}))
		generator := NewArkPetImageGenerator("secret-key", "")
		generator.endpoint = server.URL
		_, err := generator.Generate(context.Background(), testImage(t, "png"), "idel", func(string) {})
		server.Close()
		if err == nil || strings.Contains(err.Error(), "secret-key") {
			t.Fatalf("status %d: upstream failure ignored or leaked: %v", status, err)
		}
	}
}
