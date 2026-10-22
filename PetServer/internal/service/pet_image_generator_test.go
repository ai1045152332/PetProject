package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/draw"
	"image/gif"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testPetSheet(t *testing.T) []byte {
	t.Helper()
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	for i := 0; i < 16; i++ {
		x, y := (i%4)*256+70+i%3, (i/4)*256+70
		draw.Draw(im, image.Rect(x, y, x+100, y+130), image.NewUniform(color.NRGBA{R: 180, G: 120, B: 60, A: 255}), image.Point{}, draw.Src)
	}
	var b bytes.Buffer
	if err := png.Encode(&b, im); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func TestOpenRouterPetGenerationContractAndGIF(t *testing.T) {
	sheet := testPetSheet(t)
	original := testImage(t, "jpeg")
	portraitPrompt, animationPrompt, err := petPromptsForState("focus")
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "POST" || r.URL.Path != "/api/v1/images" || r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("incorrect OpenRouter request")
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Error("OpenRouter must receive JSON")
		}
		var payload map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		for field, want := range map[string]string{"model": "openai/gpt-image-2.5-sunburst", "background": "transparent", "output_format": "png", "size": "1024x1024", "quality": "medium"} {
			var got string
			_ = json.Unmarshal(payload[field], &got)
			if got != want {
				t.Errorf("%s=%q", field, got)
			}
		}
		var n int
		_ = json.Unmarshal(payload["n"], &n)
		if n != 1 {
			t.Error("expected one output image")
		}
		if _, ok := payload["input_fidelity"]; ok {
			t.Error("OpenAI-only multipart fields must not be forwarded")
		}
		var provider struct {
			AllowFallbacks bool `json:"allow_fallbacks"`
		}
		if json.Unmarshal(payload["provider"], &provider) != nil || provider.AllowFallbacks {
			t.Error("unverified fallback must be disabled")
		}
		var refs []struct {
			Type     string `json:"type"`
			ImageURL struct {
				URL string `json:"url"`
			} `json:"image_url"`
		}
		if json.Unmarshal(payload["input_references"], &refs) != nil || len(refs) != 1 || refs[0].Type != "image_url" {
			t.Error("missing reference image")
			w.WriteHeader(400)
			return
		}
		mime := "image/png"
		if calls == 1 {
			mime = "image/jpeg"
		}
		prefix := "data:" + mime + ";base64,"
		if !strings.HasPrefix(refs[0].ImageURL.URL, prefix) {
			t.Error("incorrect reference MIME")
		}
		input, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(refs[0].ImageURL.URL, prefix))
		if err != nil {
			t.Error(err)
		}
		var prompt string
		_ = json.Unmarshal(payload["prompt"], &prompt)
		if calls == 1 {
			if !bytes.Equal(input, original) || prompt != portraitPrompt {
				t.Error("portrait must reference original upload")
			}
		} else if calls == 2 {
			if !bytes.Equal(input, sheet) || prompt != animationPrompt {
				t.Error("animation must reference beautified portrait")
			}
		} else {
			t.Error("unexpected paid retry")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(sheet)}}})
	}))
	defer server.Close()
	generator := NewOpenRouterPetImageGenerator("test-key", "openai/gpt-image-2.5-sunburst")
	generator.endpoint = server.URL + "/api/v1/images"
	var stages []string
	data, err := generator.Generate(context.Background(), original, "focus", func(stage string) { stages = append(stages, stage) })
	if err != nil {
		t.Fatal(err)
	}
	if petFrameModeAnimated {
		if calls != 2 || strings.Join(stages, ",") != "beautifying,animating,encoding" {
			t.Fatalf("calls %d stages %v", calls, stages)
		}
		animation, err := gif.DecodeAll(bytes.NewReader(data))
		if err != nil {
			t.Fatal(err)
		}
		if len(animation.Image) != 30 || animation.LoopCount != 0 || animation.Config.Width != 256 || animation.Config.Height != 256 {
			t.Fatal("invalid GIF animation")
		}
		for i, frame := range animation.Image {
			_, _, _, alpha := frame.At(0, 0).RGBA()
			_, _, _, petAlpha := frame.At(90, 90).RGBA()
			if alpha != 0 || petAlpha == 0 || animation.Delay[i] != 10 || animation.Disposal[i] != gif.DisposalBackground {
				t.Fatal("GIF transparency/timing/disposal incorrect")
			}
		}
		return
	}
	// Single-frame mode: exactly one billed request, portrait only, transparent PNG out.
	if calls != 1 || strings.Join(stages, ",") != "beautifying" {
		t.Fatalf("single-frame calls %d stages %v", calls, stages)
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width != 1024 || cfg.Height != 1024 {
		t.Fatalf("single-frame portrait is not a 1024 PNG: %+v %v", cfg, err)
	}
}
func TestOpenRouterPetFailuresAreSafe(t *testing.T) {
	if NewOpenRouterPetImageGenerator("", "") != nil {
		t.Fatal("missing API key should disable generation")
	}
	for _, status := range []int{400, 401, 402, 403, 429, 500, 200} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{"error":{"message":"secret-key"},"data":[{"b64_json":"invalid"}]}`))
			}))
			defer server.Close()
			generator := NewOpenRouterPetImageGenerator("secret-key", "")
			generator.endpoint = server.URL
			_, err := generator.Generate(context.Background(), testImage(t, "png"), "idel", func(string) {})
			if err == nil || strings.Contains(err.Error(), "secret-key") {
				t.Fatal("upstream failure ignored or leaked")
			}
		})
	}
	generator := NewOpenRouterPetImageGenerator("key", "")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("cancelled request reached upstream")
		w.WriteHeader(500)
	}))
	defer server.Close()
	generator.endpoint = server.URL
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := generator.Generate(ctx, testImage(t, "png"), "idel", func(string) {}); err == nil {
		t.Fatal("cancelled generation succeeded")
	}
}
func TestPetGIFRejectsOpaqueAndEmptyFrames(t *testing.T) {
	for _, im := range []image.Image{image.NewNRGBA(image.Rect(0, 0, 1024, 1024)), image.NewUniform(color.White)} {
		// Uniform has unbounded dimensions; make a finite opaque fixture.
		finite := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
		draw.Draw(finite, finite.Bounds(), im, image.Point{}, draw.Src)
		var data bytes.Buffer
		_ = png.Encode(&data, finite)
		if _, err := petSheetGIF(data.Bytes()); err == nil {
			t.Fatal("invalid alpha/empty frame accepted")
		}
	}
	// Valid PNG with content in only one cell must not turn into an almost-empty animation.
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, image.Rect(20, 20, 200, 200), image.NewUniform(color.White), image.Point{}, draw.Src)
	var data bytes.Buffer
	_ = png.Encode(&data, im)
	if _, err := petSheetGIF(data.Bytes()); err == nil {
		t.Fatal("missing animation cells accepted")
	}
}

func TestSeedreamContractAndChromaGIF(t *testing.T) {
	transparent := testPetSheet(t)
	decoded, err := png.Decode(bytes.NewReader(transparent))
	if err != nil {
		t.Fatal(err)
	}
	green := image.NewNRGBA(decoded.Bounds())
	draw.Draw(green, green.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	draw.Draw(green, green.Bounds(), decoded, image.Point{}, draw.Over)
	// This disconnected green eye must survive background removal.
	green.SetNRGBA(110, 110, color.NRGBA{G: 255, A: 255})
	var encoded bytes.Buffer
	_ = png.Encode(&encoded, green)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var payload map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		for field, want := range map[string]string{"model": "bytedance-seed/seedream-4.5", "resolution": "2K", "aspect_ratio": "1:1"} {
			var got string
			_ = json.Unmarshal(payload[field], &got)
			if got != want {
				t.Errorf("%s=%s", field, got)
			}
		}
		for _, field := range []string{"quality", "background", "output_format", "size"} {
			if _, ok := payload[field]; ok {
				t.Errorf("unsupported parameter %s", field)
			}
		}
		var prompt string
		_ = json.Unmarshal(payload["prompt"], &prompt)
		if !strings.Contains(prompt, "#00FF00") {
			t.Error("missing chroma instructions")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(encoded.Bytes()), "media_type": "image/png"}}})
	}))
	defer server.Close()
	generator := NewOpenRouterPetImageGenerator("test-key", "")
	generator.endpoint = server.URL
	output, err := generator.Generate(context.Background(), testImage(t, "jpeg"), "sleep", func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	if petFrameModeAnimated {
		animation, err := gif.DecodeAll(bytes.NewReader(output))
		if err != nil || len(animation.Image) != 30 || calls != 2 {
			t.Fatal("Seedream GIF failed", err)
		}
		_, _, _, a := animation.Image[0].At(0, 0).RGBA()
		if a != 0 {
			t.Fatal("green background remains opaque")
		}
		_, _, _, a = animation.Image[0].At(110, 110).RGBA()
		if a == 0 {
			t.Fatal("green eye removed")
		}
		return
	}
	// Single-frame mode: one billed request returns the chroma-cleaned transparent portrait PNG.
	if calls != 1 {
		t.Fatalf("single-frame Seedream made %d requests, want 1", calls)
	}
	portrait, err := png.Decode(bytes.NewReader(output))
	if err != nil {
		t.Fatal("single-frame Seedream output is not a PNG", err)
	}
	_, _, _, a := portrait.At(0, 0).RGBA()
	if a != 0 {
		t.Fatal("green background remains opaque")
	}
	_, _, _, a = portrait.At(110, 110).RGBA()
	if a == 0 {
		t.Fatal("green eye removed")
	}
}
func TestSeedreamOpaqueBackgroundRejected(t *testing.T) {
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	var data bytes.Buffer
	_ = png.Encode(&data, im)
	if _, err := prepareSeedreamImage(data.Bytes(), false); err == nil {
		t.Fatal("non-chroma opaque output accepted")
	}
}

func TestSeedreamNormalizes2KOutput(t *testing.T) {
	im := image.NewNRGBA(image.Rect(0, 0, 2048, 2048))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(600, 600, 1400, 1500), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
	var data bytes.Buffer
	_ = png.Encode(&data, im)
	output, err := prepareSeedreamImage(data.Bytes(), false)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := png.Decode(bytes.NewReader(output))
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Bounds().Dx() != 1024 || decoded.Bounds().Dy() != 1024 {
		t.Fatal("2K normalization failed")
	}
	_, _, _, a := decoded.At(0, 0).RGBA()
	if a != 0 {
		t.Fatal("2K green background not removed")
	}
	_, _, _, a = decoded.At(500, 500).RGBA()
	if a == 0 {
		t.Fatal("2K pet removed")
	}
}
func TestOpenRouter400DoesNotBlamePhoto(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":{"message":"bytedance-seed/seedream-4.5 requires at least 3,686,400 output pixels"}}`))
	}))
	defer server.Close()
	generator := NewOpenRouterPetImageGenerator("test-key", "")
	generator.endpoint = server.URL
	_, err := generator.Generate(context.Background(), testImage(t, "png"), "idel", func(string) {})
	if err == nil || !strings.Contains(err.Error(), "2K") || strings.Contains(err.Error(), "清晰") {
		t.Fatalf("misleading error: %v", err)
	}
}
