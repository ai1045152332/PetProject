package service

// 本地抠图预览工具：PET_CHROMA_LOCAL=图片路径 go test ./internal/service -run TestChromaLocalPreview
// 走与 prepareSeedreamImage 完全相同的管线（keyChromaGreen + 纯色背景兜底），
// 结果写到 <原图>-keyed.png，用于人工确认当前绿幕处理对本地图片的效果。

import (
	"bytes"
	"image"
	"image/color"
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
