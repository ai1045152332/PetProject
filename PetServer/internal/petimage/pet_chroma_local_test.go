package petimage

// 本地人工校验工具集（都不走网络、不计费，不给环境变量就跳过）：
//   - TestChromaLocalPreview：PET_CHROMA_LOCAL=图片路径，走与 prepareSeedreamImage 完全相同的
//     管线（keyChromaGreen + 纯色背景兜底），结果写到 <原图>-keyed.png，用于确认绿幕处理效果。
//   - TestSheetMotionLocal：PET_SHEET_LOCAL=16格sheet路径，量化帧动画到底动了没有。
//     不能拿成品 GIF 的帧差当依据：GIF 每帧重新量化到 256 色，内容完全相同也会算出非零差值。

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	_ "image/jpeg"
	"image/png"
	"os"
	"testing"
)

func TestChromaLocalPreview(t *testing.T) {
	src := os.Getenv("PET_CHROMA_LOCAL")
	if src == "" {
		t.Skip("需要 PET_CHROMA_LOCAL 指定本地图片")
	}
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	im, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	canvas := squareCanvas(im)
	// 已被旧版管线抠过一轮的图：四角透明导致边缘绿色占比不够，lightGreenMatcher 不会启用。
	// 先把透明区回填成边缘主绿，恢复成“原始绿幕图”的形态，再走生产管线。
	if key, share := edgeGreenKey(canvas); share > 0 {
		if transparentShare(canvas) > 0.05 {
			for y := 0; y < petCanvas; y++ {
				for x := 0; x < petCanvas; x++ {
					if c := canvas.NRGBAAt(x, y); c.A < 128 {
						canvas.SetNRGBA(x, y, key)
					}
				}
			}
		}
	}
	out, transparent := keyChromaGreen(canvas, false)
	mode := "chroma"
	if transparent < petCanvas*petCanvas/petTransparentShare {
		if solid, ok := keySolidBackground(canvas); ok {
			out, mode = solid, "solid-fallback"
			transparent = countTransparent(out)
		}
	}
	var buf bytes.Buffer
	if err = png.Encode(&buf, out); err != nil {
		t.Fatal(err)
	}
	outPath := chromaLocalOutPath(src)
	if err = os.WriteFile(outPath, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	opaque := petCanvas*petCanvas - transparent
	green := countGreenishOpaque(out)
	t.Logf("输入=%s 模式=%s 透明=%dpx(%.1f%%) 残余绿色不透明像素=%d(占不透明%.2f%%) 输出=%s",
		src, mode, transparent, float64(transparent)*100/(petCanvas*petCanvas),
		green, float64(green)*100/float64(max(opaque, 1)), outPath)
}

// squareCanvas 把任意图片放入 1024 方形画布：先补成正方（透明留边，边缘种子可直接漫入），再缩放到 petCanvas。
func squareCanvas(im image.Image) *image.NRGBA {
	b := im.Bounds()
	side := max(b.Dx(), b.Dy())
	padded := image.NewNRGBA(image.Rect(0, 0, side, side))
	offset := image.Pt((side-b.Dx())/2, (side-b.Dy())/2)
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			padded.SetNRGBA(offset.X+x, offset.Y+y, color.NRGBAModel.Convert(im.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA))
		}
	}
	return resampleSquare(padded, side)
}

func chromaLocalOutPath(src string) string {
	for _, ext := range []string{".png", ".jpg", ".jpeg", ".PNG", ".JPG", ".JPEG"} {
		if len(src) > len(ext) && src[len(src)-len(ext):] == ext {
			return src[:len(src)-len(ext)] + "-keyed.png"
		}
	}
	return src + "-keyed.png"
}

func countTransparent(im *image.NRGBA) int {
	n := 0
	for i := 0; i < petCanvas*petCanvas; i++ {
		if im.NRGBAAt(i%petCanvas, i/petCanvas).A == 0 {
			n++
		}
	}
	return n
}

func transparentShare(im *image.NRGBA) float64 {
	return float64(countTransparent(im)) / float64(petCanvas*petCanvas)
}

// countGreenishOpaque 用宽松阈值统计抠图后仍然发绿的不透明像素，模拟肉眼在桌面上看到的绿边/绿块。
func countGreenishOpaque(im *image.NRGBA) int {
	n := 0
	for y := 0; y < petCanvas; y++ {
		for x := 0; x < petCanvas; x++ {
			c := im.NRGBAAt(x, y)
			if c.A >= 128 && greenDominant(c) {
				n++
			}
		}
	}
	return n
}

// TestSheetMotionLocal 把 1024×1024 的 4×4 sprite sheet 拆成 16 格，逐格报主体包围盒、
// 不透明像素数与与上一格的平均像素差，用于定性判断模型到底画了“一段动作”还是“16 张静态图”。
// 关键看包围盒逐格漂移：只在 ±2px 内抖动就是没动（抗锯齿噪声）。
//
//	PET_SHEET_LOCAL=/path/to/sheet.png go test ./internal/petimage/ -run TestSheetMotionLocal -v
func TestSheetMotionLocal(t *testing.T) {
	src := os.Getenv("PET_SHEET_LOCAL")
	if src == "" {
		t.Skip("需要 PET_SHEET_LOCAL 指定 16 格 sheet 图片")
	}
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	im, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	canvas := squareCanvas(im)
	const cell = petCanvas / 4
	type box struct{ x0, y0, x1, y1, n int }
	measure := func(c *image.NRGBA, ox, oy int) box {
		b := box{x0: cell, y0: cell, x1: -1, y1: -1}
		for y := 0; y < cell; y++ {
			for x := 0; x < cell; x++ {
				if c.NRGBAAt(ox+x, oy+y).A < 128 {
					continue
				}
				b.n++
				b.x0, b.y0 = min(b.x0, x), min(b.y0, y)
				b.x1, b.y1 = max(b.x1, x), max(b.y1, y)
			}
		}
		return b
	}
	cells := make([]box, 0, 16)
	var prev *image.NRGBA
	t.Logf("格  包围盒(x0,y0,x1,y1)   不透明px  与上一格平均差")
	for i := 0; i < 16; i++ {
		cx, cy := (i%4)*cell, (i/4)*cell
		crop := image.NewNRGBA(image.Rect(0, 0, cell, cell))
		draw.Draw(crop, crop.Bounds(), canvas, image.Pt(cx, cy), draw.Src)
		b := measure(canvas, cx, cy)
		delta := "-"
		if prev != nil {
			var sum float64
			for y := 0; y < cell; y++ {
				for x := 0; x < cell; x++ {
					a, c := prev.NRGBAAt(x, y), crop.NRGBAAt(x, y)
					sum += float64(abs(int(a.R)-int(c.R)) + abs(int(a.G)-int(c.G)) + abs(int(a.B)-int(c.B)) + abs(int(a.A)-int(c.A)))
				}
			}
			delta = fmt.Sprintf("%.2f", sum/float64(cell*cell))
		}
		prev = crop
		cells = append(cells, b)
		t.Logf("%2d  (%3d,%3d,%3d,%3d) %7d  %s", i, b.x0, b.y0, b.x1, b.y1, b.n, delta)
	}
	// 包围盒四边的逐格漂移量就是“主体真的在动”的硬指标：
	// 模型只改纹理不改轮廓时，漂移会落在 ±2px 的抗锯齿噪声里。
	span := func(get func(box) int) int {
		lo, hi := get(cells[0]), get(cells[0])
		for _, b := range cells {
			lo, hi = min(lo, get(b)), max(hi, get(b))
		}
		return hi - lo
	}
	t.Logf("包围盒漂移：左=%d 上=%d 右=%d 下=%d px（≤2 即基本静止，≥8 才有可见动作）",
		span(func(b box) int { return b.x0 }), span(func(b box) int { return b.y0 }),
		span(func(b box) int { return b.x1 }), span(func(b box) int { return b.y1 }))
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
