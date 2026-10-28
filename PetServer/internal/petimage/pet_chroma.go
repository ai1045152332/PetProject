package petimage

import (
	"bytes"
	_ "embed"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"log"
	"math"
)

//go:embed prompts/pet_chroma_v2.txt
var petChromaPrompt string

// petCanvas 是宠物素材的固定输出边长，抠图判定均基于这个正方形。
const petCanvas = 1024

// petOutputCanvas 是成品落盘/下发的边长：1024 只服务于抠图判定，
// 展示端最多是放大后的 160pt 窗口（Retina 下约 600px），512 足够且单张体积约降为 1/4。
const petOutputCanvas = 512

// 抠图后至少要保留一部分透明背景（带电脑等大道具的图也留得下），主体也不得几乎为空。
const (
	petTransparentShare = 25  // 1/25 = 4% 透明
	petOpaqueShare      = 100 // 1/100 = 1% 主体
)

func seedreamPrompt(prompt string) string { return prompt + "\n\n" + petChromaPrompt }

// petBackgroundError 表示生成图里没有可安全去除的背景，通常意味着模型没按提示词画色键绿幕。
// 生成器据此在同一个任务内自动再请求一次（不额外消耗用户配额）。
type petBackgroundError struct{ reason string }

func (e petBackgroundError) Error() string { return e.reason }

// prepareSeedreamImage 把 Seedream 出的不透明方图变成带真透明的 1024 素材。
// 首选按提示词要求的 #00FF00 色键抠除；模型偶尔不听话（尤其带道具的状态），
// 再按四周边缘主色抠一次纯色背景兜底，仍不行才判定失败。
func prepareSeedreamImage(data []byte, sheet bool) ([]byte, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "png" && format != "jpeg") || cfg.Width < 16 || cfg.Height < 16 || cfg.Width > 4096 || cfg.Height > 4096 || cfg.Width != cfg.Height {
		return nil, fmt.Errorf("Seedream 返回图片尺寸或格式不正确，请重试")
	}
	source, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("Seedream 图片损坏")
	}
	canvas := resampleSquare(source, cfg.Width)
	out, transparent := keyChromaGreen(canvas, sheet)
	if transparent < petCanvas*petCanvas/petTransparentShare {
		if solid, ok := keySolidBackground(canvas); ok {
			out = solid
		}
	}
	var result bytes.Buffer
	if err = png.Encode(&result, out); err != nil {
		return nil, err
	}
	if _, err = decodeTransparentPNG(result.Bytes()); err != nil {
		log.Printf("[pet-images] 抠图失败：sheet=%v %v %s", sheet, err, alphaSummary(out))
		return nil, petBackgroundError{err.Error()}
	}
	return result.Bytes(), nil
}

// downscalePetPNG 把超大成品素材按整数比例缩到 petOutputCanvas 再落盘。
// 非 PNG、非正方或边长不整除的图片原样返回——缩小只是优化，绝不允许丢图。
func downscalePetPNG(data []byte) ([]byte, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || format != "png" || cfg.Width != cfg.Height || cfg.Width <= petOutputCanvas || cfg.Width%petOutputCanvas != 0 {
		return data, nil
	}
	source, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return data, nil
	}
	side, k := petOutputCanvas, cfg.Width/petOutputCanvas
	out := image.NewNRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			// 先在预乘空间求 k×k 块均值再还原直通 alpha，透明像素不会把边缘颜色渗进主体。
			var r, g, b, a float64
			for dy := 0; dy < k; dy++ {
				for dx := 0; dx < k; dx++ {
					c := color.NRGBAModel.Convert(source.At(x*k+dx, y*k+dy)).(color.NRGBA)
					r += float64(c.R) * float64(c.A)
					g += float64(c.G) * float64(c.A)
					b += float64(c.B) * float64(c.A)
					a += float64(c.A)
				}
			}
			if a == 0 {
				out.SetNRGBA(x, y, color.NRGBA{})
				continue
			}
			out.SetNRGBA(x, y, color.NRGBA{
				R: uint8(r/a + 0.5), G: uint8(g/a + 0.5), B: uint8(b/a + 0.5),
				A: uint8(a/float64(k*k) + 0.5),
			})
		}
	}
	var result bytes.Buffer
	if err = png.Encode(&result, out); err != nil {
		return nil, err
	}
	return result.Bytes(), nil
}

// resampleSquare 双线性缩放到 1024×1024，2K 输出也能保持 4×4 网格对齐。
func resampleSquare(source image.Image, side int) *image.NRGBA {
	im := image.NewNRGBA(image.Rect(0, 0, petCanvas, petCanvas))
	for y := 0; y < petCanvas; y++ {
		for x := 0; x < petCanvas; x++ {
			sx := math.Max(0, (float64(x)+0.5)*float64(side)/petCanvas-0.5)
			sy := math.Max(0, (float64(y)+0.5)*float64(side)/petCanvas-0.5)
			x0, y0 := int(sx), int(sy)
			x1, y1 := min(x0+1, side-1), min(y0+1, side-1)
			fx, fy := sx-float64(x0), sy-float64(y0)
			corners := [4]color.NRGBA{
				color.NRGBAModel.Convert(source.At(x0, y0)).(color.NRGBA),
				color.NRGBAModel.Convert(source.At(x1, y0)).(color.NRGBA),
				color.NRGBAModel.Convert(source.At(x0, y1)).(color.NRGBA),
				color.NRGBAModel.Convert(source.At(x1, y1)).(color.NRGBA),
			}
			weights := [4]float64{(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy}
			var r, g, b, a float64
			for i, c := range corners {
				r += float64(c.R) * weights[i]
				g += float64(c.G) * weights[i]
				b += float64(c.B) * weights[i]
				a += float64(c.A) * weights[i]
			}
			im.SetNRGBA(x, y, color.NRGBA{uint8(r + 0.5), uint8(g + 0.5), uint8(b + 0.5), uint8(a + 0.5)})
		}
	}
	return im
}

// keyChromaGreen 按绿幕色键抠除背景，返回结果与透明像素数。
// Seedream 不提供真 alpha：从画面（动画图则是每格）边界开始漫水，
// 先用严格判据找鲜艳绿幕种子，再用宽松判据吃掉与绿幕混色的柔边，
// 不连通画面边界的绿色（眼睛、斑纹）保持原样。
func keyChromaGreen(im *image.NRGBA, sheet bool) (*image.NRGBA, int) {
	chroma := func(c color.NRGBA, minGreen, minDelta int) bool {
		return c.A < 128 || (int(c.G) >= minGreen && int(c.G)-int(c.R) > minDelta && int(c.G)-int(c.B) > minDelta)
	}
	strict := func(x, y int) bool { return chroma(im.NRGBAAt(x, y), 140, 70) }
	soft := func(x, y int) bool { return chroma(im.NRGBAAt(x, y), 110, 40) }
	// 模型常把 #00FF00 画成 #C0E080 这类浅绿/黄绿，G-R 只有 20~50，落不进 soft 的固定阈值，
	// 只能抠掉少数更艳的像素、留下大片绿色。此时改用跟随边缘主色的色度判据。
	var backdrop color.NRGBA
	if adaptive, key, ok := lightGreenMatcher(im); ok {
		shift := func(x, y int) bool { return adaptive(im.NRGBAAt(x, y)) }
		soft = shift
		backdrop = key
	}
	out := cloneCanvas(im)
	visited := make([]bool, petCanvas*petCanvas)
	queue := make([]int, 0, petCanvas*petCanvas)
	push := func(x, y int, ok func(int, int) bool) {
		i := y*petCanvas + x
		if !visited[i] && ok(x, y) {
			visited[i] = true
			queue = append(queue, i)
		}
	}
	cell := petCanvas
	if sheet {
		cell = 256
	}
	seed := func(ok func(int, int) bool) {
		for cy := 0; cy < petCanvas; cy += cell {
			for cx := 0; cx < petCanvas; cx += cell {
				for i := 0; i < cell; i++ {
					push(cx+i, cy, ok)
					push(cx+i, cy+cell-1, ok)
					push(cx, cy+i, ok)
					push(cx+cell-1, cy+i, ok)
				}
			}
		}
	}
	seed(strict)
	if len(queue) == 0 {
		// 绿幕被画暗/画灰时严格种子会全军覆没，退回宽松判据重新起种。
		seed(soft)
	}
	if len(queue) == 0 {
		return out, 0
	}
	for head := 0; head < len(queue); head++ {
		i := queue[head]
		x, y := i%petCanvas, i/petCanvas
		out.SetNRGBA(x, y, color.NRGBA{})
		if x > 0 {
			push(x-1, y, soft)
		}
		if x < petCanvas-1 {
			push(x+1, y, soft)
		}
		if y > 0 {
			push(x, y-1, soft)
		}
		if y < petCanvas-1 {
			push(x, y+1, soft)
		}
	}
	transparent := len(queue)
	// 前腿之间、道具下方这类被主体整个围住的同色背景与画面边界不连通，漫水永远够不到，
	// 按面积阈值单独清掉，否则最终素材上会留下几块绿色碎片。
	if backdrop.A != 0 {
		transparent += sweepBackdropRemnants(out, backdrop)
	}
	// Despill：仍贴着抠除区的毛发像素保留了 JPEG 振铃与柔边的绿偏，
	// 把绿色压回红/蓝水平，避免桌面上一圈绿边。
	for y := 0; y < petCanvas; y++ {
		for x := 0; x < petCanvas; x++ {
			c := out.NRGBAAt(x, y)
			if c.A >= 128 && int(c.G) > int(c.R) && int(c.G) > int(c.B) && touchesKeyed(out, x, y) {
				base := int(c.R)
				if int(c.B) > base {
					base = int(c.B)
				}
				limit := min(base+12, 255)
				if int(c.G) > limit {
					out.SetNRGBA(x, y, color.NRGBA{R: c.R, G: uint8(limit), B: c.B, A: c.A})
				}
			}
		}
	}
	return out, transparent
}

// sweepBackdropRemnants 清掉被主体包围、不与画面边界连通的同色背景孤岛。
// 只处理达到面积阈值的大块背景，避免误吃主体上的绿色装饰。
func sweepBackdropRemnants(out *image.NRGBA, key color.NRGBA) int {
	k := chromaVector(key)
	matches := func(c color.NRGBA) bool {
		return c.A >= 128 && greenDominant(c) && chromaDistance(chromaVector(c), k) <= 0.10
	}
	const minBlob = petCanvas * petCanvas / 2000
	visited := make([]bool, petCanvas*petCanvas)
	removed := 0
	blob := make([]int, 0, 1024)
	for start := 0; start < petCanvas*petCanvas; start++ {
		if visited[start] {
			continue
		}
		visited[start] = true
		if !matches(out.NRGBAAt(start%petCanvas, start/petCanvas)) {
			continue
		}
		blob = append(blob[:0], start)
		for head := 0; head < len(blob); head++ {
			i := blob[head]
			x, y := i%petCanvas, i/petCanvas
			for _, d := range [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}} {
				nx, ny := x+d[0], y+d[1]
				if nx < 0 || ny < 0 || nx > petCanvas-1 || ny > petCanvas-1 {
					continue
				}
				j := ny*petCanvas + nx
				if visited[j] || !matches(out.NRGBAAt(nx, ny)) {
					continue
				}
				visited[j] = true
				blob = append(blob, j)
			}
		}
		if len(blob) < minBlob {
			continue
		}
		for _, i := range blob {
			out.SetNRGBA(i%petCanvas, i/petCanvas, color.NRGBA{})
		}
		removed += len(blob)
	}
	return removed
}

// lightGreenMatcher 处理模型把色键绿画成浅绿/黄绿（如 #C0E080）的情况。
// 前提：四周确实被这种浅绿占满、且画面中心的主体不是同一色度，
// 否则（饱和绿幕、或绿色宠物配浅绿底）返回 false，继续用固定阈值。
func lightGreenMatcher(im *image.NRGBA) (func(color.NRGBA) bool, color.NRGBA, bool) {
	key, share := edgeGreenKey(im)
	if share < 0.6 {
		return nil, color.NRGBA{}, false
	}
	if int(key.G)-max(int(key.R), int(key.B)) >= 60 {
		// 仍算饱和绿幕：固定阈值能更好地区分黄绿柔边。
		return nil, color.NRGBA{}, false
	}
	k := chromaVector(key)
	if !hasSubjectInCenter(im, k) {
		// 主体与背景同色度（绿色宠物 + 浅绿背景）：按色度漫水会连主体一起吃掉。
		return nil, color.NRGBA{}, false
	}
	return func(c color.NRGBA) bool {
		if c.A < 128 {
			return true
		}
		// 只认与边缘背景同一色度的绿。不能再叠加“鲜艳绿”固定阈值：
		// 那只适合纯色绿幕，用在浅绿背景下会直接把同样鲜艳的绿色主体吃掉。
		return greenDominant(c) && chromaDistance(chromaVector(c), k) <= 0.10
	}, key, true
}

// edgeGreenKey 汇总四周边缘带里所有绿色系像素的平均色。
// 不用 edgeDominantColor 的主色桶：浅绿背景往往带渐变，主色桶占比会被打散。
func edgeGreenKey(im *image.NRGBA) (color.NRGBA, float64) {
	const band = 6
	scan := func(x, y int, sum *[3]float64, n, total *int) {
		c := im.NRGBAAt(x, y)
		*total++
		if c.A < 128 || !greenDominant(c) {
			return
		}
		sum[0] += float64(c.R)
		sum[1] += float64(c.G)
		sum[2] += float64(c.B)
		*n++
	}
	var sum [3]float64
	n, total := 0, 0
	for i := 0; i < petCanvas; i++ {
		for d := 0; d < band; d++ {
			scan(i, d, &sum, &n, &total)
			scan(i, petCanvas-1-d, &sum, &n, &total)
			scan(d, i, &sum, &n, &total)
			scan(petCanvas-1-d, i, &sum, &n, &total)
		}
	}
	if n == 0 || total == 0 {
		return color.NRGBA{}, 0
	}
	return color.NRGBA{
		R: uint8(sum[0]/float64(n) + 0.5),
		G: uint8(sum[1]/float64(n) + 0.5),
		B: uint8(sum[2]/float64(n) + 0.5),
		A: 255,
	}, float64(n) / float64(total)
}

// hasSubjectInCenter 统计画面中心区域：除与背景同色度的像素外，是否还剩足够多的主体像素。
// 不能直接用中心平均色，因为背景（尤其浅绿）常常在中心区占大多数，会把平均值拉向背景。
func hasSubjectInCenter(im *image.NRGBA, key [3]float64) bool {
	const lo, hi = petCanvas * 3 / 10, petCanvas * 7 / 10
	total, subject := 0, 0
	for y := lo; y < hi; y++ {
		for x := lo; x < hi; x++ {
			c := im.NRGBAAt(x, y)
			if c.A < 128 {
				continue
			}
			total++
			if chromaDistance(chromaVector(c), key) > 0.10 {
				subject++
			}
		}
	}
	return total > 0 && subject*100 >= total*3
}

// greenDominant 判断颜色是否以绿为主：绿色通道最亮且明显高出另两个通道。
// 阈值取 10，刚好区分浅绿背景（G-R≈30）与米白/浅黄背景（G 甚至不是最亮通道）。
func greenDominant(c color.NRGBA) bool {
	return int(c.G) >= int(c.R) && int(c.G) >= int(c.B) && int(c.G)-max(int(c.R), int(c.B)) >= 10
}

// chromaVector 把颜色投影到亮度无关的色度单位向量，用于比较“同一种底色但明暗不一”。
func chromaVector(c color.NRGBA) [3]float64 {
	sum := float64(c.R) + float64(c.G) + float64(c.B)
	if sum < 1 {
		return [3]float64{}
	}
	return [3]float64{float64(c.R) / sum, float64(c.G) / sum, float64(c.B) / sum}
}

func chromaDistance(a, b [3]float64) float64 {
	dr, dg, db := a[0]-b[0], a[1]-b[1], a[2]-b[2]
	return math.Sqrt(dr*dr + dg*dg + db*db)
}

// keySolidBackground 是"模型没画绿幕"时的兜底：只在四周确实是一整块干净纯色、
// 且与画面中心的主体颜色明显不同时，才从边界漫水抠掉该颜色。
// 白猫配白底这类主体与背景同色的图会被拒绝，交给重试换一张。
func keySolidBackground(im *image.NRGBA) (*image.NRGBA, bool) {
	const tolerance = 30.0
	key, share, spread := edgeDominantColor(im)
	if share < 0.6 || spread > 18 || colorDistance(key, centerColor(im)) < 2*tolerance {
		return nil, false
	}
	out := cloneCanvas(im)
	visited := make([]bool, petCanvas*petCanvas)
	queue := make([]int, 0, petCanvas*petCanvas)
	push := func(x, y int) {
		i := y*petCanvas + x
		if visited[i] || colorDistance(im.NRGBAAt(x, y), key) > tolerance {
			return
		}
		visited[i] = true
		queue = append(queue, i)
	}
	for i := 0; i < petCanvas; i++ {
		push(i, 0)
		push(i, petCanvas-1)
		push(0, i)
		push(petCanvas-1, i)
	}
	for head := 0; head < len(queue); head++ {
		i := queue[head]
		x, y := i%petCanvas, i/petCanvas
		out.SetNRGBA(x, y, color.NRGBA{})
		if x > 0 {
			push(x-1, y)
		}
		if x < petCanvas-1 {
			push(x+1, y)
		}
		if y > 0 {
			push(x, y-1)
		}
		if y < petCanvas-1 {
			push(x, y+1)
		}
	}
	if len(queue) < petCanvas*petCanvas/petTransparentShare {
		return nil, false
	}
	featherSolidEdge(out, key, tolerance)
	return out, true
}

// featherSolidEdge 把紧贴抠除区、颜色介于背景与主体之间的过渡像素做成半透明，
// 避免非绿背景抠图后留下锯齿。
func featherSolidEdge(im *image.NRGBA, key color.NRGBA, tolerance float64) {
	for y := 1; y < petCanvas-1; y++ {
		for x := 1; x < petCanvas-1; x++ {
			c := im.NRGBAAt(x, y)
			if c.A == 0 || !touchesKeyed(im, x, y) {
				continue
			}
			d := colorDistance(c, key)
			if d <= tolerance || d > 2*tolerance {
				continue
			}
			im.SetNRGBA(x, y, color.NRGBA{R: c.R, G: c.G, B: c.B, A: uint8((d - tolerance) / tolerance * 255)})
		}
	}
}

// edgeDominantColor 统计四周边缘带的主色，返回该色、占比与簇内颜色散布。
func edgeDominantColor(im *image.NRGBA) (color.NRGBA, float64, float64) {
	const band = 6
	type bucket struct{ r, g, b, rr, gg, bb, n float64 }
	buckets := make(map[uint32]*bucket)
	total := 0
	scan := func(x, y int) {
		c := im.NRGBAAt(x, y)
		if c.A < 128 {
			return
		}
		k := uint32(c.R>>4)<<8 | uint32(c.G>>4)<<4 | uint32(c.B>>4)
		b := buckets[k]
		if b == nil {
			b = &bucket{}
			buckets[k] = b
		}
		r, g, blue := float64(c.R), float64(c.G), float64(c.B)
		b.r += r
		b.g += g
		b.b += blue
		b.rr += r * r
		b.gg += g * g
		b.bb += blue * blue
		b.n++
		total++
	}
	for i := 0; i < petCanvas; i++ {
		for d := 0; d < band; d++ {
			scan(i, d)
			scan(i, petCanvas-1-d)
			scan(d, i)
			scan(petCanvas-1-d, i)
		}
	}
	if total == 0 {
		return color.NRGBA{}, 0, 0
	}
	var best *bucket
	for _, b := range buckets {
		if best == nil || b.n > best.n {
			best = b
		}
	}
	stats := func(sum, sq float64) (float64, float64) {
		mean := sum / best.n
		variance := sq/best.n - mean*mean
		return mean, math.Sqrt(max(variance, 0))
	}
	r, rs := stats(best.r, best.rr)
	g, gs := stats(best.g, best.gg)
	b, bs := stats(best.b, best.bb)
	key := color.NRGBA{R: uint8(r + 0.5), G: uint8(g + 0.5), B: uint8(b + 0.5), A: 255}
	return key, best.n / float64(total), max(rs, max(gs, bs))
}

// centerColor 取画面中心区域平均色，代表主体。
func centerColor(im *image.NRGBA) color.NRGBA {
	const lo, hi = petCanvas * 3 / 10, petCanvas * 7 / 10
	var r, g, b, n float64
	for y := lo; y < hi; y++ {
		for x := lo; x < hi; x++ {
			c := im.NRGBAAt(x, y)
			if c.A < 128 {
				continue
			}
			r += float64(c.R)
			g += float64(c.G)
			b += float64(c.B)
			n++
		}
	}
	if n == 0 {
		return color.NRGBA{A: 255}
	}
	return color.NRGBA{R: uint8(r/n + 0.5), G: uint8(g/n + 0.5), B: uint8(b/n + 0.5), A: 255}
}

func colorDistance(a, b color.NRGBA) float64 {
	dr, dg, db := float64(a.R)-float64(b.R), float64(a.G)-float64(b.G), float64(a.B)-float64(b.B)
	return math.Sqrt(dr*dr + dg*dg + db*db)
}

func cloneCanvas(im *image.NRGBA) *image.NRGBA {
	out := image.NewNRGBA(image.Rect(0, 0, petCanvas, petCanvas))
	copy(out.Pix, im.Pix)
	return out
}

func alphaSummary(im *image.NRGBA) string {
	transparent := 0
	for y := 0; y < petCanvas; y++ {
		for x := 0; x < petCanvas; x++ {
			if im.NRGBAAt(x, y).A < 128 {
				transparent++
			}
		}
	}
	return fmt.Sprintf("transparent=%d opaque=%d", transparent, petCanvas*petCanvas-transparent)
}

// touchesKeyed reports whether any 4-neighbor is already fully transparent.
func touchesKeyed(im *image.NRGBA, x, y int) bool {
	for _, d := range [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}} {
		nx, ny := x+d[0], y+d[1]
		if nx < 0 || ny < 0 || nx > petCanvas-1 || ny > petCanvas-1 {
			continue
		}
		if im.NRGBAAt(nx, ny).A == 0 {
			return true
		}
	}
	return false
}
