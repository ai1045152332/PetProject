package petimage

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
func TestSeedreamRemovesSoftFringeAndDespillsEdge(t *testing.T) {
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	// Soft green-tinted fringe around the subject: below the strict vivid threshold.
	draw.Draw(im, image.Rect(397, 397, 603, 603), image.NewUniform(color.NRGBA{R: 90, G: 150, B: 90, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(400, 400, 600, 600), image.NewUniform(color.NRGBA{R: 180, G: 120, B: 60, A: 255}), image.Point{}, draw.Src)
	// Fainter olive pixel that survives the soft flood must be despilled, not eaten.
	im.SetNRGBA(398, 500, color.NRGBA{R: 130, G: 170, B: 120, A: 255})
	// Detached pure-green eye inside the fur must keep its exact color.
	im.SetNRGBA(500, 450, color.NRGBA{G: 255, A: 255})
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
	if _, _, _, a := decoded.At(0, 0).RGBA(); a != 0 {
		t.Fatal("background not removed")
	}
	if _, _, _, a := decoded.At(398, 420).RGBA(); a != 0 {
		t.Fatal("soft fringe left opaque")
	}
	olive := color.NRGBAModel.Convert(decoded.At(398, 500)).(color.NRGBA)
	if olive.A < 128 || int(olive.G) > int(olive.R)+12 {
		t.Fatalf("olive edge not despilled or eaten: %v", olive)
	}
	fur := color.NRGBAModel.Convert(decoded.At(400, 500)).(color.NRGBA)
	if fur != (color.NRGBA{R: 180, G: 120, B: 60, A: 255}) {
		t.Fatalf("warm fur edge altered: %v", fur)
	}
	eye := color.NRGBAModel.Convert(decoded.At(500, 450)).(color.NRGBA)
	if eye != (color.NRGBA{G: 255, A: 255}) {
		t.Fatalf("disconnected green eye damaged: %v", eye)
	}
}

func TestSeedreamDespillsWideFringeAndClearsGreenPockets(t *testing.T) {
	// 真实照片上的绿幕残留分两类：①耳尖/趾缝那种几像素宽、整条被染绿的细毛发；
	// ②前腿之间被主体整个围住、漫水够不到的纯绿孤岛。鲜艳绿幕下旧逻辑只处理 1px 圈，
	// 且 backdrop 恒为零、孤岛清理整段不跑，两类都会留在成品上。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	// 3px 宽的柔边：G-R 只有 30，落在 soft 阈值外，抠不掉，只能靠 despill 压。
	draw.Draw(im, image.Rect(297, 297, 704, 704), image.NewUniform(color.NRGBA{R: 170, G: 200, B: 150, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(300, 300, 700, 700), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(450, 450, 550, 550), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
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
	if _, _, _, a := decoded.At(500, 500).RGBA(); a != 0 {
		t.Fatal("enclosed vivid green pocket left opaque")
	}
	outer := color.NRGBAModel.Convert(decoded.At(297, 620)).(color.NRGBA)
	if outer.A < 128 || int(outer.G) > int(outer.R)+2 {
		t.Fatalf("outer fringe not despilled: %v", outer)
	}
	for x := 297; x <= 299; x++ {
		c := color.NRGBAModel.Convert(decoded.At(x, 620)).(color.NRGBA)
		if int(c.G)-max(int(c.R), int(c.B)) > 30 {
			t.Fatalf("fringe column x=%d still green: %v", x, c)
		}
	}
	if fur := color.NRGBAModel.Convert(decoded.At(300, 620)).(color.NRGBA); fur != (color.NRGBA{R: 150, G: 90, B: 50, A: 255}) {
		t.Fatalf("warm fur at the band edge altered: %v", fur)
	}
}

func TestSeedreamHealsSpillGreenOnBodyAndPrunesSpeckles(t *testing.T) {
	// 真实成品上的两块硬伤（用户反馈“丑”的主因，实测自一遍线上产物）：
	//   ① 抚摸态胸腹有一块亮绿，961 个饱和绿像素占主体 1.0%。它不是背景绿——被毛色拉偏后
	//      色度距离 0.62，既过不了漫水也过不了孤岛清理的 0.10 阈值；挖成透明又会在身上打洞。
	//   ② 轮廓外散着一堆 2~7px、alpha 64~191 的半透明碎屑，深色壁纸下就是一圈脏边。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(300, 300, 700, 700), image.NewUniform(color.NRGBA{R: 180, G: 120, B: 60, A: 255}), image.Point{}, draw.Src)
	// 溢色核心外面还裹着一圈淡绿晕染，填色时不能被这一圈污染。
	draw.Draw(im, image.Rect(444, 444, 516, 516), image.NewUniform(color.NRGBA{R: 180, G: 222, B: 160, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(450, 450, 510, 510), image.NewUniform(color.NRGBA{R: 112, G: 208, B: 103, A: 255}), image.Point{}, draw.Src)
	// 轮廓外的半透明碎屑，模拟绿幕毛尖残留。
	for _, p := range []image.Point{{200, 200}, {201, 200}, {202, 201}} {
		im.SetNRGBA(p.X, p.Y, color.NRGBA{R: 202, G: 202, B: 186, A: 128})
	}
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
	greens := func(p image.Point) (color.NRGBA, int) {
		c := color.NRGBAModel.Convert(decoded.At(p.X, p.Y)).(color.NRGBA)
		return c, int(c.G) - max(int(c.R), int(c.B))
	}
	// ① 溢色核心必须还在（不能挖洞），且绿已经被压掉、填成周围毛色。
	core, delta := greens(image.Point{480, 480})
	if core.A < 128 {
		t.Fatalf("spill core punched into a hole: %v", core)
	}
	if delta > 12 {
		t.Fatalf("spill core still green: %v", core)
	}
	if core.R < 150 || core.B > 100 {
		t.Fatalf("spill core not filled with surrounding fur: %v", core)
	}
	// 核心外的淡绿晕染要被逐层压掉。
	if halo, d := greens(image.Point{446, 480}); halo.A < 128 || d > 12 {
		t.Fatalf("spill halo left green: %v", halo)
	}
	// 正常毛色一个像素都不能动。
	if fur, _ := greens(image.Point{320, 320}); fur != (color.NRGBA{R: 180, G: 120, B: 60, A: 255}) {
		t.Fatalf("clean fur altered: %v", fur)
	}
	// ② 轮廓外半透明碎屑必须清掉。
	for _, p := range []image.Point{{200, 200}, {201, 200}, {202, 201}} {
		if _, _, _, a := decoded.At(p.X, p.Y).RGBA(); a != 0 {
			t.Fatalf("speck at %v left opaque", p)
		}
	}
}

func TestSeedreamFallsBackToSolidEdgeColor(t *testing.T) {
	// 模型没画绿幕、改画米色纯色背景时，按边缘主色兜底抠除。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{R: 238, G: 231, B: 214, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(300, 260, 724, 820), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
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
	if _, _, _, a := decoded.At(4, 4).RGBA(); a != 0 {
		t.Fatal("solid edge background not removed")
	}
	if _, _, _, a := decoded.At(512, 540).RGBA(); a == 0 {
		t.Fatal("pet body removed")
	}
}
func TestSeedreamRejectsSubjectMatchingBackground(t *testing.T) {
	// 白猫配白底：兜底会连主体一起吃掉，必须拒绝并交给重试，而不是产出残缺素材。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{R: 250, G: 250, B: 250, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(300, 300, 724, 724), image.NewUniform(color.NRGBA{R: 255, G: 255, B: 255, A: 255}), image.Point{}, draw.Src)
	var data bytes.Buffer
	_ = png.Encode(&data, im)
	if _, err := prepareSeedreamImage(data.Bytes(), false); err == nil {
		t.Fatal("subject sharing the background color accepted")
	}
}
func TestSeedreamAcceptsLargeSubject(t *testing.T) {
	// 主体几乎占满画面时（如道具、大额头形象），绿背景只剩几个百分点也算有效。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(20, 20, 1004, 1004), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
	var data bytes.Buffer
	_ = png.Encode(&data, im)
	if _, err := prepareSeedreamImage(data.Bytes(), false); err != nil {
		t.Fatal("large subject with a thin background margin rejected:", err)
	}
}
func TestSeedreamRetriesOnceWhenBackgroundUnusable(t *testing.T) {
	white := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(white, white.Bounds(), image.NewUniform(color.White), image.Point{}, draw.Src)
	var first bytes.Buffer
	_ = png.Encode(&first, white)
	green := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	draw.Draw(green, green.Bounds(), image.NewUniform(color.NRGBA{G: 255, A: 255}), image.Point{}, draw.Src)
	draw.Draw(green, image.Rect(300, 300, 724, 724), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
	var second bytes.Buffer
	_ = png.Encode(&second, green)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		body := second.Bytes()
		if calls == 1 {
			body = first.Bytes()
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": base64.StdEncoding.EncodeToString(body), "media_type": "image/png"}}})
	}))
	defer server.Close()
	generator := NewOpenRouterPetImageGenerator("key", "")
	generator.endpoint = server.URL
	output, err := generator.Generate(context.Background(), testImage(t, "jpeg"), "focus", func(string) {})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("background retry made %d requests, want 2", calls)
	}
	decoded, err := png.Decode(bytes.NewReader(output))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, a := decoded.At(0, 0).RGBA(); a != 0 {
		t.Fatal("retried output keeps an opaque background")
	}
}

// lightGreenBackdrop 生成模型实际会画出的浅绿→黄绿渐变背景（#D0F0A0 → #B0D878）。
func lightGreenBackdrop(im *image.NRGBA) {
	for y := 0; y < 1024; y++ {
		for x := 0; x < 1024; x++ {
			t := float64(x+y) / 2048
			im.SetNRGBA(x, y, color.NRGBA{
				R: uint8(208 - 32*t), G: uint8(240 - 16*t), B: uint8(160 - 40*t), A: 255,
			})
		}
	}
}

// opaqueGreenShare 统计不透明像素中仍然偏绿的比例，用来断言背景没被大量留下。
func opaqueGreenShare(im image.Image) float64 {
	opaque, green := 0, 0
	b := im.Bounds()
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			c := color.NRGBAModel.Convert(im.At(x, y)).(color.NRGBA)
			if c.A < 128 {
				continue
			}
			opaque++
			if int(c.G)-max(int(c.R), int(c.B)) > 15 {
				green++
			}
		}
	}
	if opaque == 0 {
		return 0
	}
	return float64(green) / float64(opaque)
}

func TestSeedreamRemovesLightGreenBackdrop(t *testing.T) {
	// 模型把 #00FF00 画成浅绿时，固定阈值只能抠掉少数更艳的像素，
	// 真实批次里 focus/hide 就这样留下一大片绿色。必须按边缘主色补抠。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	lightGreenBackdrop(im)
	draw.Draw(im, image.Rect(320, 260, 700, 820), image.NewUniform(color.NRGBA{R: 150, G: 90, B: 50, A: 255}), image.Point{}, draw.Src)
	// 两条腿之间被主体整个围住的背景块，与画面边界不连通，也要清掉。
	draw.Draw(im, image.Rect(430, 700, 470, 760), image.NewUniform(color.NRGBA{R: 196, G: 232, B: 136, A: 255}), image.Point{}, draw.Src)
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
	for _, p := range [][2]int{{4, 4}, {1020, 4}, {4, 1020}, {1020, 1020}, {300, 900}} {
		if _, _, _, a := decoded.At(p[0], p[1]).RGBA(); a != 0 {
			t.Fatalf("light green background left opaque at %v", p)
		}
	}
	if _, _, _, a := decoded.At(512, 540).RGBA(); a == 0 {
		t.Fatal("pet body removed")
	}
	if _, _, _, a := decoded.At(450, 730).RGBA(); a != 0 {
		t.Fatal("enclosed background pocket left opaque")
	}
	if share := opaqueGreenShare(decoded); share > 0.005 {
		t.Fatalf("%.2f%% of the opaque pixels are still green", share*100)
	}
}

func TestSeedreamKeepsGreenSubjectOnLightBackdrop(t *testing.T) {
	// 绿色宠物 + 浅绿背景：抠背景不能连宠物一起吃掉。
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	lightGreenBackdrop(im)
	draw.Draw(im, image.Rect(320, 260, 700, 820), image.NewUniform(color.NRGBA{R: 70, G: 150, B: 60, A: 255}), image.Point{}, draw.Src)
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
	if _, _, _, a := decoded.At(4, 4).RGBA(); a != 0 {
		t.Fatal("light green background not removed")
	}
	if _, _, _, a := decoded.At(512, 540).RGBA(); a == 0 {
		t.Fatal("green pet removed with the background")
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
