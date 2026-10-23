package service

import (
	"bytes"
	_ "embed"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
)

//go:embed prompts/pet_chroma_v2.txt
var petChromaPrompt string

func seedreamPrompt(prompt string) string { return prompt + "\n\n" + petChromaPrompt }

// Seedream does not advertise native alpha. Remove chroma pixels connected
// to the canvas/cell boundaries, preserving disconnected green eyes and markings.
// The flood starts on vivid background (strict) and keeps growing through the
// soft anti-aliased fringe (loose), so only a thin green-tinted band can be eaten;
// whatever survives on the new edge gets its green cast clamped away (despill).
func prepareSeedreamImage(data []byte, sheet bool) ([]byte, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "png" && format != "jpeg") || cfg.Width < 16 || cfg.Height < 16 || cfg.Width > 4096 || cfg.Height > 4096 || cfg.Width != cfg.Height {
		return nil, fmt.Errorf("Seedream 返回图片尺寸或格式不正确，请重试")
	}
	source, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("Seedream 图片损坏")
	}
	im := image.NewNRGBA(image.Rect(0, 0, 1024, 1024))
	for y := 0; y < 1024; y++ {
		for x := 0; x < 1024; x++ {
			// Bilinear sampling keeps the 4x4 grid exact even when the provider returns 2K.
			sx := math.Max(0, (float64(x)+0.5)*float64(cfg.Width)/1024-0.5)
			sy := math.Max(0, (float64(y)+0.5)*float64(cfg.Height)/1024-0.5)
			x0, y0 := int(sx), int(sy)
			x1, y1 := min(x0+1, cfg.Width-1), min(y0+1, cfg.Height-1)
			fx, fy := sx-float64(x0), sy-float64(y0)
			colors := [4]color.NRGBA{color.NRGBAModel.Convert(source.At(x0, y0)).(color.NRGBA), color.NRGBAModel.Convert(source.At(x1, y0)).(color.NRGBA), color.NRGBAModel.Convert(source.At(x0, y1)).(color.NRGBA), color.NRGBAModel.Convert(source.At(x1, y1)).(color.NRGBA)}
			weights := [4]float64{(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy}
			var r, g, b, a float64
			for i, c := range colors {
				r += float64(c.R) * weights[i]
				g += float64(c.G) * weights[i]
				b += float64(c.B) * weights[i]
				a += float64(c.A) * weights[i]
			}
			im.SetNRGBA(x, y, color.NRGBA{uint8(r + 0.5), uint8(g + 0.5), uint8(b + 0.5), uint8(a + 0.5)})
		}
	}
	chroma := func(c color.NRGBA, minGreen, minDelta int) bool {
		return c.A < 128 || (int(c.G) >= minGreen && int(c.G)-int(c.R) > minDelta && int(c.G)-int(c.B) > minDelta)
	}
	// Boundary seeds must look like the requested vivid chroma green.
	strict := func(x, y int) bool { return chroma(im.NRGBAAt(x, y), 140, 70) }
	// Expansion also accepts the muted green/gray blend pixels clinging to the edge.
	soft := func(x, y int) bool { return chroma(im.NRGBAAt(x, y), 110, 40) }
	visited := make([]bool, 1024*1024)
	queue := make([]int, 0, 1024*1024)
	push := func(x, y int, ok func(int, int) bool) {
		i := y*1024 + x
		if !visited[i] && ok(x, y) {
			visited[i] = true
			queue = append(queue, i)
		}
	}
	cell := 1024
	if sheet {
		cell = 256
	}
	for cy := 0; cy < 1024; cy += cell {
		for cx := 0; cx < 1024; cx += cell {
			for i := 0; i < cell; i++ {
				push(cx+i, cy, strict)
				push(cx+i, cy+cell-1, strict)
				push(cx, cy+i, strict)
				push(cx+cell-1, cy+i, strict)
			}
		}
	}
	for head := 0; head < len(queue); head++ {
		i := queue[head]
		x, y := i%1024, i/1024
		im.SetNRGBA(x, y, color.NRGBA{})
		if x > 0 {
			push(x-1, y, soft)
		}
		if x < 1023 {
			push(x+1, y, soft)
		}
		if y > 0 {
			push(x, y-1, soft)
		}
		if y < 1023 {
			push(x, y+1, soft)
		}
	}
	// Despill: fur pixels still touching the keyed-out area keep a green tint
	// from JPEG ringing and soft edges; clamp green down toward red/blue.
	for y := 0; y < 1024; y++ {
		for x := 0; x < 1024; x++ {
			c := im.NRGBAAt(x, y)
			if c.A >= 128 && int(c.G) > int(c.R) && int(c.G) > int(c.B) && touchesKeyed(im, x, y) {
				base := int(c.R)
				if int(c.B) > base {
					base = int(c.B)
				}
				limit := min(base+12, 255)
				if int(c.G) > limit {
					im.SetNRGBA(x, y, color.NRGBA{R: c.R, G: uint8(limit), B: c.B, A: c.A})
				}
			}
		}
	}
	var result bytes.Buffer
	if err = png.Encode(&result, im); err != nil {
		return nil, err
	}
	// Do not silently ship a solid background or an empty extraction.
	if _, err = decodeTransparentPNG(result.Bytes()); err != nil {
		return nil, fmt.Errorf("Seedream 背景提取失败，请重试：%w", err)
	}
	return result.Bytes(), nil
}

// touchesKeyed reports whether any 4-neighbor is already fully transparent.
func touchesKeyed(im *image.NRGBA, x, y int) bool {
	for _, d := range [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}} {
		nx, ny := x+d[0], y+d[1]
		if nx < 0 || ny < 0 || nx > 1023 || ny > 1023 {
			continue
		}
		if im.NRGBAAt(nx, ny).A == 0 {
			return true
		}
	}
	return false
}
