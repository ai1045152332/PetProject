package petimage

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// PetPromptVersion 记录成品是由哪一版提示词契约生成的（仅落档供排查，客户端不读）。
// v5：基准图改为写实比例 + 分层毛流的插画口径（去掉 v4 的“大头圆眼萌化”），
// 状态文案整套重写；色键提示词同步收紧为禁止绿幕反光溢到主体上。
const PetPromptVersion = "pet-seedream-state-v5"
const DefaultPetImageModel = "bytedance-seed/seedream-4.5"

// petFrameModeAnimated 保留两套生成能力：false=单帧（当前写死，每个状态一次美化请求出透明 PNG）；
// true=两阶段动画（额外一次动画帧请求并合成 GIF）。要切回动画只改这一个常量并重新编译。
const petFrameModeAnimated = false

//go:embed prompts/pet_portrait_v2.txt
var petPortraitPrompt string

//go:embed prompts/pet_animation_v1.txt
var petAnimationPrompt string

type PetImageGenerator interface {
	Generate(context.Context, []byte, string, func(string)) ([]byte, error)
}

type OpenRouterPetImageGenerator struct {
	key, model, endpoint string
	client               *http.Client
}

func NewOpenRouterPetImageGenerator(key, model string) *OpenRouterPetImageGenerator {
	if strings.TrimSpace(key) == "" {
		return nil
	}
	if model == "" {
		model = DefaultPetImageModel
	}
	return &OpenRouterPetImageGenerator{key: strings.TrimSpace(key), model: model, endpoint: "https://openrouter.ai/api/v1/images", client: &http.Client{Timeout: 4 * time.Minute}}
}

// Model 返回当前使用的模型 ID，供启动日志确认接入的生成管线。
func (g *OpenRouterPetImageGenerator) Model() string { return g.model }

func (g *OpenRouterPetImageGenerator) Generate(ctx context.Context, original []byte, state string, progress func(string)) ([]byte, error) {
	portraitPrompt, animationPrompt, err := petPromptsForState(state)
	if err != nil {
		return nil, err
	}
	progress("beautifying")
	seedream := strings.HasPrefix(g.model, "bytedance-seed/seedream-")
	if seedream {
		portraitPrompt = seedreamPrompt(portraitPrompt)
		animationPrompt = seedreamPrompt(animationPrompt)
	}
	portrait, err := g.editSeedream(ctx, original, portraitPrompt, seedream, false, progress)
	if err != nil {
		return nil, err
	}
	if _, err = decodeTransparentPNG(portrait); err != nil {
		return nil, err
	}
	if !petFrameModeAnimated {
		// 单帧管线到此完成：不再提交第二次（动画帧）计费请求。
		return portrait, nil
	}
	progress("animating")
	sheet, err := g.edit(ctx, portrait, animationPrompt)
	if err != nil {
		return nil, err
	}
	progress("encoding")
	if seedream {
		sheet, err = prepareSeedreamImage(sheet, true)
		if err != nil {
			return nil, err
		}
	}
	return petSheetGIF(sheet)
}

// editSeedream 发送一次生成请求；模型没画出可抠除的背景时，同一任务内自动重发一次。
// 用户配额在提交时已扣过，重试不再扣次，只是多一次上游调用。
func (g *OpenRouterPetImageGenerator) editSeedream(ctx context.Context, input []byte, prompt string, seedream, sheet bool, progress func(string)) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		output, err := g.edit(ctx, input, prompt)
		if err != nil {
			return nil, err
		}
		if !seedream {
			return output, nil
		}
		output, err = prepareSeedreamImage(output, sheet)
		if err == nil {
			return output, nil
		}
		var background petBackgroundError
		if attempt == 0 && errors.As(err, &background) && ctx.Err() == nil {
			progress("beautifying")
			continue
		}
		return nil, err
	}
}
func (g *OpenRouterPetImageGenerator) edit(ctx context.Context, input []byte, prompt string) ([]byte, error) {
	mime := http.DetectContentType(input)
	if mime != "image/png" && mime != "image/jpeg" {
		return nil, fmt.Errorf("参考图必须为 PNG/JPEG")
	}
	// OpenRouter's dedicated Images API uses JSON and inline reference images, not OpenAI multipart edits.
	payload := map[string]any{
		"model": g.model, "prompt": prompt, "n": 1, "size": "1024x1024", "quality": "medium",
		"background": "transparent", "output_format": "png",
		"input_references": []map[string]any{{"type": "image_url", "image_url": map[string]string{
			"url": "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(input),
		}}},
		"provider": map[string]any{"allow_fallbacks": false},
	}
	if strings.HasPrefix(g.model, "bytedance-seed/seedream-") {
		delete(payload, "quality")
		delete(payload, "background")
		delete(payload, "output_format")
		delete(payload, "size")
		// Seedream 4.5 enforces >= 3,686,400 pixels despite advertising a 1K tier.
		payload["resolution"] = "2K"
		payload["aspect_ratio"] = "1:1"
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+g.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := g.client.Do(req)
	if err != nil {
		// 根本没发出/没接住响应，上游不会计费：可退。
		return nil, petProviderFault{msg: "OpenRouter 请求失败或超时，请稍后重试"}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (32<<20)+1))
	if err != nil || len(data) > 32<<20 {
		return nil, fmt.Errorf("OpenRouter 返回图片过大或读取失败")
	}
	if resp.StatusCode != http.StatusOK {
		// Do not expose upstream bodies, request headers or API keys to clients/logs.
		// 鉴权/模型访问/容量类失败几乎都是配置问题（Key 过期、漏配、欠费、上游拒绝），与用户照片无关，
		// 必须在服务端日志留痕，不能只以气泡文案回到客户端。
		if petRefundableStatus(resp.StatusCode) {
			log.Printf("[pet-images][WARN] OpenRouter 不可用（HTTP %d），模型: %s；本次不扣用户生成次数，请检查 OPENROUTER_API_KEY 有效期与模型开通", resp.StatusCode, g.model)
		}
		switch resp.StatusCode {
		case 400:
			var upstream struct {
				Error struct {
					Message string `json:"message"`
				} `json:"error"`
			}
			if json.Unmarshal(data, &upstream) == nil && strings.Contains(upstream.Error.Message, "requires at least") && strings.Contains(upstream.Error.Message, "output pixels") {
				return nil, fmt.Errorf("OpenRouter 拒绝图片尺寸（HTTP 400）：所选模型要求更高的输出分辨率，请使用 2K 或更高")
			}
			return nil, fmt.Errorf("OpenRouter 拒绝生成参数（HTTP 400），请检查模型分辨率、尺寸及输入格式；这不一定是照片内容问题")
		case 401, 403:
			return nil, petProviderFault{msg: "OpenRouter 授权或模型访问失败，请联系管理员检查配置"}
		case 402:
			return nil, petProviderFault{msg: "OpenRouter 余额不足，请联系管理员充值"}
		case 429:
			return nil, petProviderFault{msg: "OpenRouter 配额不足或请求过多，请稍后重试"}
		default:
			msg := fmt.Sprintf("OpenRouter 图片生成失败（HTTP %d），请稍后重试或联系管理员检查接口配置", resp.StatusCode)
			if petRefundableStatus(resp.StatusCode) {
				return nil, petProviderFault{msg: msg}
			}
			return nil, errors.New(msg)
		}
	}
	var out struct {
		Data []struct {
			Image     string `json:"b64_json"`
			MediaType string `json:"media_type"`
		} `json:"data"`
	}
	if json.Unmarshal(data, &out) != nil || len(out.Data) != 1 {
		return nil, fmt.Errorf("OpenRouter 图片响应无效")
	}
	if out.Data[0].MediaType != "" && out.Data[0].MediaType != "image/png" &&
		!(strings.HasPrefix(g.model, "bytedance-seed/seedream-") && out.Data[0].MediaType == "image/jpeg") {
		return nil, fmt.Errorf("OpenRouter 未返回要求的 PNG 图片")
	}
	decoded, err := base64.StdEncoding.DecodeString(out.Data[0].Image)
	if err != nil || len(decoded) == 0 {
		return nil, fmt.Errorf("OpenRouter 图片响应无效")
	}
	return decoded, nil
}
func decodeTransparentPNG(data []byte) (image.Image, error) {
	cfg, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width < 16 || cfg.Height < 16 || cfg.Width > 2048 || cfg.Height > 2048 {
		return nil, fmt.Errorf("生成图片尺寸或格式无效")
	}
	im, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("生成图片损坏")
	}
	transparent, opaque := 0, 0
	for y := 0; y < cfg.Height; y++ {
		for x := 0; x < cfg.Width; x++ {
			_, _, _, a := im.At(x, y).RGBA()
			if a < 0x8000 {
				transparent++
			} else {
				opaque++
			}
		}
	}
	if transparent < cfg.Width*cfg.Height/petTransparentShare || opaque < cfg.Width*cfg.Height/petOpaqueShare {
		return nil, fmt.Errorf("生成图片缺少有效透明背景或宠物主体，请重试")
	}
	return im, nil
}

// Quantize all frames with a single palette and explicit 1-bit alpha to avoid color flicker.
func petSheetGIF(data []byte) ([]byte, error) {
	sheet, err := decodeTransparentPNG(data)
	if err != nil {
		return nil, err
	}
	if sheet.Bounds().Dx() != 1024 || sheet.Bounds().Dy() != 1024 {
		return nil, fmt.Errorf("动画帧网格尺寸不正确，请重试")
	}
	palette := color.Palette{color.NRGBA{}}
	for r := 0; r < 6; r++ {
		for g := 0; g < 7; g++ {
			for b := 0; b < 6; b++ {
				palette = append(palette, color.NRGBA{uint8(r * 255 / 5), uint8(g * 255 / 6), uint8(b * 255 / 5), 255})
			}
		}
	}
	frames := make([]*image.Paletted, 16)
	for i := 0; i < 16; i++ {
		frame := image.NewPaletted(image.Rect(0, 0, 256, 256), palette)
		opaque := 0
		for y := 0; y < 256; y++ {
			for x := 0; x < 256; x++ {
				c := color.NRGBAModel.Convert(sheet.At((i%4)*256+x, (i/4)*256+y)).(color.NRGBA)
				if c.A < 128 {
					continue
				}
				if x < 4 || x >= 252 || y < 4 || y >= 252 {
					return nil, fmt.Errorf("生成宠物超出动画格边界，请重试")
				}
				frame.SetColorIndex(x, y, uint8(1+((int(c.R)*5+127)/255)*42+((int(c.G)*6+127)/255)*6+(int(c.B)*5+127)/255))
				opaque++
			}
		}
		if opaque < 256*256/100 || opaque > 256*256*9/10 {
			return nil, fmt.Errorf("生成动画存在空帧或不透明背景，请重试")
		}
		frames[i] = frame
	}
	animation := gif.GIF{LoopCount: 0, Config: image.Config{ColorModel: palette, Width: 256, Height: 256}}
	appendFrame := func(frame *image.Paletted) {
		animation.Image = append(animation.Image, frame)
		animation.Delay = append(animation.Delay, 10)
		animation.Disposal = append(animation.Disposal, gif.DisposalBackground)
	}
	for _, frame := range frames {
		appendFrame(frame)
	}
	for i := 14; i > 0; i-- {
		appendFrame(frames[i])
	}
	var result bytes.Buffer
	if err = gif.EncodeAll(&result, &animation); err != nil {
		return nil, err
	}
	return result.Bytes(), nil
}
