package petimage

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestArkGeneratorLive 直连火山方舟 Seedream 官方接口做端到端联调：会真实计费，默认跳过。
// 只有显式设 PET_ARK_LIVE=1 才运行，例如：
//
//	PETSERVER_ARK_API_KEY=ark-xxx \
//	PET_ARK_LIVE=1 \
//	PET_ARK_LIVE_INPUT=/path/to/pet.png \
//	go test ./internal/petimage/ -run TestArkGeneratorLive -v -timeout 6m
//
// 相关环境变量：
//   - PETSERVER_ARK_API_KEY       官方接口密钥（必填，否则跳过并提示）
//   - PETSERVER_ARK_IMAGE_MODEL   可选，留空用默认 Seedream 5.0 pro
//   - PET_ARK_LIVE_INPUT          可选，你自己的宠物照路径；不给则用内置合成图占位
//   - PET_ARK_LIVE_STATE          可选，目标状态（idel/sleep/pet/focus/hide），默认 idel
//   - PET_ARK_LIVE_OUT            可选，成品写出路径；默认落到系统临时目录便于查看
//
// 不给 PET_ARK_LIVE_INPUT 时合成图只为验证连通与抠图管线，不代表真实生成质量；想看效果请传入真实照片。
func TestArkGeneratorLive(t *testing.T) {
	if os.Getenv("PET_ARK_LIVE") != "1" {
		t.Skip("联网计费测试：设 PET_ARK_LIVE=1 且配好 PETSERVER_ARK_API_KEY 才会运行")
	}
	generator := NewArkPetImageGenerator(os.Getenv("PETSERVER_ARK_API_KEY"), os.Getenv("PETSERVER_ARK_IMAGE_MODEL"))
	if generator == nil {
		t.Fatal("需要 PETSERVER_ARK_API_KEY 才能跑联调（NewArkPetImageGenerator 返回 nil）")
	}
	t.Logf("官方模型: %s，接口: %s", generator.Model(), generator.endpoint)

	input := liveArkInput(t)
	state := os.Getenv("PET_ARK_LIVE_STATE")
	if state == "" {
		state = "idel"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	start := time.Now()
	output, err := generator.Generate(ctx, input, state, func(stage string) { t.Logf("  进度: %s", stage) })
	if err != nil {
		t.Fatalf("生图失败（state=%s）: %v", state, err)
	}
	t.Logf("耗时 %s，输出 %d 字节", time.Since(start).Round(time.Millisecond), len(output))

	img, err := decodeTransparentPNG(output)
	if err != nil {
		t.Fatalf("输出不是合法透明 PNG: %v", err)
	}

	// 统计透明占比，验证绿幕色键抠图确实生效（背景应被抠成透明）。
	bounds := img.Bounds()
	transparent, total := 0, 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			total++
			if _, _, _, a := img.At(x, y).RGBA(); a == 0 {
				transparent++
			}
		}
	}
	t.Logf("透明像素占比: %.1f%% (%d/%d)", 100*float64(transparent)/float64(total), transparent, total)
	if transparent == 0 {
		t.Error("没有任何透明像素，色键抠图可能未生效")
	}

	out := os.Getenv("PET_ARK_LIVE_OUT")
	if out == "" {
		out = filepath.Join(os.TempDir(), "ark-live-"+state+".png")
	}
	if err := os.WriteFile(out, output, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("成品已写出: %s", out)
}

// TestArkGeneratorLiveSheet 走“帧动画”分支做端到端联调：先出基准图，再让模型画 4×4=16 格
// sprite sheet，最后切片拼成 GIF。会真实计费两次（portrait + sheet），默认跳过。
//
//	PETSERVER_ARK_API_KEY=ark-xxx PET_ARK_LIVE=1 \
//	PET_ARK_LIVE_INPUT=/path/to/pet.jpg \
//	go test ./internal/petimage/ -run TestArkGeneratorLiveSheet -v -timeout 8m
//
// 产物写到 PET_ARK_LIVE_SHEET_OUT 目录（默认系统临时目录）：基准图 PNG + 16 格 sheet PNG + 成品 GIF。
//
// 调动画提示词时给 PET_ARK_LIVE_PORTRAIT 指定一张已有的基准图，就只花 sheet 这一次计费，
// 且与上一轮用同一只宠物做 A/B，不会被基准图的随机差异干扰。
func TestArkGeneratorLiveSheet(t *testing.T) {
	if os.Getenv("PET_ARK_LIVE") != "1" {
		t.Skip("联网计费测试：设 PET_ARK_LIVE=1 且配好 PETSERVER_ARK_API_KEY 才会运行")
	}
	generator := NewArkPetImageGenerator(os.Getenv("PETSERVER_ARK_API_KEY"), os.Getenv("PETSERVER_ARK_IMAGE_MODEL"))
	if generator == nil {
		t.Fatal("需要 PETSERVER_ARK_API_KEY 才能跑联调")
	}
	t.Logf("官方模型: %s（帧动画联调：portrait + sheet 两次计费）", generator.Model())

	input := liveArkInput(t)
	state := os.Getenv("PET_ARK_LIVE_STATE")
	if state == "" {
		state = "idel"
	}
	portraitPrompt, animationPrompt, err := petPromptsForState(state)
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Minute)
	defer cancel()

	// 1) 基准图（透明 PNG）：能用已有的则不重新生成，省一次计费并保证 A/B 同一张脸。
	var portrait []byte
	if cached := os.Getenv("PET_ARK_LIVE_PORTRAIT"); cached != "" {
		portrait, err = os.ReadFile(cached)
		if err != nil {
			t.Fatalf("读取 PET_ARK_LIVE_PORTRAIT 失败: %v", err)
		}
		t.Logf("复用缓存基准图（不计费）: %s", cached)
	} else {
		start := time.Now()
		portrait, err = generator.editChroma(ctx, input, seedreamPrompt(portraitPrompt), false, func(s string) { t.Logf("  [portrait] %s", s) })
		if err != nil {
			t.Fatalf("基准图生成失败: %v", err)
		}
		t.Logf("基准图 OK：%d 字节，%s", len(portrait), time.Since(start).Round(time.Millisecond))
	}
	if _, err = decodeTransparentPNG(portrait); err != nil {
		t.Fatalf("基准图不是合法透明 PNG: %v", err)
	}

	// 2) 让模型画 4×4 sprite sheet，再抠图切片成 GIF
	start := time.Now()
	sheet, err := generator.edit(ctx, portrait, seedreamPrompt(animationPrompt))
	if err != nil {
		t.Fatalf("sprite sheet 生成失败: %v", err)
	}
	sheet, err = prepareSeedreamImage(sheet, true)
	if err != nil {
		t.Fatalf("sprite sheet 抠图失败（多半是模型没画出规整 16 格）: %v", err)
	}
	gifBytes, err := petSheetGIF(sheet)
	if err != nil {
		t.Fatalf("切片成 GIF 失败: %v", err)
	}
	t.Logf("帧动画 OK：%d 字节 GIF，%s", len(gifBytes), time.Since(start).Round(time.Millisecond))

	dir := os.Getenv("PET_ARK_LIVE_SHEET_OUT")
	if dir == "" {
		dir = os.TempDir()
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	pngPath := filepath.Join(dir, "ark-sheet-portrait-"+state+".png")
	sheetPath := filepath.Join(dir, "ark-sheet-grid-"+state+".png")
	gifPath := filepath.Join(dir, "ark-sheet-"+state+".gif")
	if err := os.WriteFile(pngPath, portrait, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sheetPath, sheet, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(gifPath, gifBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("基准图: %s", pngPath)
	t.Logf("16 格 sheet: %s", sheetPath)
	t.Logf("成品 GIF: %s", gifPath)
}

// TestArkChromaReplayOnRawCache 把官方原图（未抠图）缓存下来，之后离线重放抠图管线。
// 调色键阈值/despill 时不必每次再花一次计费请求：首次真发一次 edit 并写缓存，
// 以后只要缓存文件在就完全不走网络。
//
// 首次（1 次计费）：
//
//	PETSERVER_ARK_API_KEY=ark-xxx PET_ARK_LIVE=1 PET_ARK_LIVE_INPUT=/path/to/pet.jpg \
//	  PET_ARK_LIVE_RAW=/tmp/ark-raw/idel.png go test ./internal/petimage/ -run TestArkChromaReplayOnRawCache -v
//
// 之后调完阈值只重跑抠图（不计费、不联网，去掉 PET_ARK_LIVE 即可）：
//
//	PET_ARK_LIVE_RAW=/tmp/ark-raw/idel.png go test ./internal/petimage/ -run TestArkChromaReplayOnRawCache -v
func TestArkChromaReplayOnRawCache(t *testing.T) {
	raw := os.Getenv("PET_ARK_LIVE_RAW")
	if raw == "" {
		raw = filepath.Join(os.TempDir(), "ark-live-raw.png")
	}
	data, err := os.ReadFile(raw)
	if err != nil {
		if os.Getenv("PET_ARK_LIVE") != "1" {
			t.Skipf("缓存 %s 不存在，且未开 PET_ARK_LIVE：要么先跑一次计费生成缓存，要么直接指定一张官方原图", raw)
		}
		generator := NewArkPetImageGenerator(os.Getenv("PETSERVER_ARK_API_KEY"), os.Getenv("PETSERVER_ARK_IMAGE_MODEL"))
		if generator == nil {
			t.Fatal("需要 PETSERVER_ARK_API_KEY 才能拉取原图")
		}
		state := os.Getenv("PET_ARK_LIVE_STATE")
		if state == "" {
			state = "idel"
		}
		portraitPrompt, _, err := petPromptsForState(state)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		data, err = generator.edit(ctx, liveArkInput(t), seedreamPrompt(portraitPrompt))
		if err != nil {
			t.Fatalf("拉取官方原图失败: %v", err)
		}
		if err = os.MkdirAll(filepath.Dir(raw), 0o755); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(raw, data, 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("官方原图已缓存（下次重跑不再计费）: %s", raw)
	}

	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("缓存的原图读不了（删掉重拉）: %v", err)
	}
	t.Logf("原图: format=%s %dx%d %d字节", format, cfg.Width, cfg.Height, len(data))

	start := time.Now()
	output, err := prepareSeedreamImage(data, false)
	if err != nil {
		t.Fatalf("抠图失败: %v", err)
	}
	img, err := decodeTransparentPNG(output)
	if err != nil {
		t.Fatal(err)
	}
	keyed, ok := img.(*image.NRGBA)
	if !ok {
		t.Fatalf("成品不是 *image.NRGBA，而是 %T", img)
	}
	out := os.Getenv("PET_ARK_LIVE_OUT")
	if out == "" {
		out = strings.TrimSuffix(raw, filepath.Ext(raw)) + "-keyed.png"
	}
	if err = os.WriteFile(out, output, 0o644); err != nil {
		t.Fatal(err)
	}
	// 直接量化“肉眼看到的绿边/绿块”：不透明但仍偏绿的像素。
	green := countGreenishOpaque(keyed)
	opaque := petCanvas*petCanvas - countTransparent(keyed)
	t.Logf("耗时 %s 成品=%s", time.Since(start).Round(time.Millisecond), out)
	t.Logf("残余绿色不透明像素=%d（占不透明 %.3f%%）", green, float64(green)*100/float64(max(opaque, 1)))
}

// liveArkInput 取用户提供的宠物照（PET_ARK_LIVE_INPUT），否则合成一张够大的灰底占位图，
// 只为把请求打到官方接口、验证管线，不代表真实生成质量。
func liveArkInput(t *testing.T) []byte {
	t.Helper()
	if path := os.Getenv("PET_ARK_LIVE_INPUT"); path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("读取 PET_ARK_LIVE_INPUT 失败: %v", err)
		}
		return data
	}
	im := image.NewNRGBA(image.Rect(0, 0, 512, 512))
	draw.Draw(im, im.Bounds(), image.NewUniform(color.NRGBA{R: 200, G: 200, B: 200, A: 255}), image.Point{}, draw.Src)
	draw.Draw(im, image.Rect(160, 140, 360, 400), image.NewUniform(color.NRGBA{R: 170, G: 120, B: 70, A: 255}), image.Point{}, draw.Src)
	var b bytes.Buffer
	if err := png.Encode(&b, im); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
