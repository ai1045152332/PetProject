package petimage

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// DefaultArkPetImageModel 火山方舟（ARK）官方 Seedream 5.0 pro 的 Model ID。
// 可用 PETSERVER_ARK_IMAGE_MODEL 覆盖（如 5.0 flash：doubao-seedream-5-0-flash-260915，或专用推理接入点 ep-…）。
const DefaultArkPetImageModel = "doubao-seedream-5-0-pro-260628"

// arkImageSize 官方请求的固定正方形边长（像素模式，宽高均为 16 的倍数）。
const arkImageSize = "2048x2048"

// ArkPetImageGenerator 直连火山方舟官方图片生成接口，是宠物 AI 生图的默认管线。
// 与 OpenRouter 中转仅在请求/响应封装上不同：色键抠图、尺寸归一、同任务重试完全复用。
type ArkPetImageGenerator struct {
	key, model, endpoint string
	client               *http.Client
}

// NewArkPetImageGenerator 未配置 API Key 时返回 nil，交由调用方回退到其它生成器。
func NewArkPetImageGenerator(key, model string) *ArkPetImageGenerator {
	if strings.TrimSpace(key) == "" {
		return nil
	}
	if model == "" {
		model = DefaultArkPetImageModel
	}
	return &ArkPetImageGenerator{
		key:      strings.TrimSpace(key),
		model:    strings.TrimSpace(model),
		endpoint: "https://ark.cn-beijing.volces.com/api/v3/images/generations",
		client:   &http.Client{Timeout: 4 * time.Minute},
	}
}

// Model 返回当前使用的官方 Model ID，供启动日志确认接入的模型。
func (g *ArkPetImageGenerator) Model() string { return g.model }

func (g *ArkPetImageGenerator) Generate(ctx context.Context, original []byte, state string, progress func(string)) ([]byte, error) {
	portraitPrompt, animationPrompt, err := petPromptsForState(state)
	if err != nil {
		return nil, err
	}
	progress("beautifying")
	// 官方 Seedream 不支持透明背景输出，一律走绿幕提示词 + 色键抠图管线。
	portrait, err := g.editChroma(ctx, original, seedreamPrompt(portraitPrompt), false, progress)
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
	sheet, err := g.edit(ctx, portrait, seedreamPrompt(animationPrompt))
	if err != nil {
		return nil, err
	}
	progress("encoding")
	sheet, err = prepareSeedreamImage(sheet, true)
	if err != nil {
		return nil, err
	}
	return petSheetGIF(sheet)
}

// editChroma 生成一帧并做色键抠图；模型没画出可抠除背景时同任务内自动重发一次。
// 用户配额在提交时已扣过，重试不再扣次，只是多一次上游调用。
func (g *ArkPetImageGenerator) editChroma(ctx context.Context, input []byte, prompt string, sheet bool, progress func(string)) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		output, err := g.edit(ctx, input, prompt)
		if err != nil {
			return nil, err
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

// edit 发送一次官方图片生成请求。官方模型输出为不透明图，交给色键管线归一。
// 注意：
//   - Seedream 5.0 pro/flash 不支持 sequential_image_generation（4.5 专有），故不下发；
//     解析时只取 data[0]，即便个别模型返回多张也只取第一张。
//   - size 必须用像素模式而非 "2K" 档位模式：档位模式下宽高比由模型自行判断，会随参考图
//     吐出长方形，而抠图管线（含 4×4 网格切帧）要求正方形；2048x2048 是官方推荐的 2K 1:1 值，
//     且正好落在 pro 的总像素上限 4194304 上。
//   - output_format 显式要 png：默认 jpeg 的压缩噪声会在绿幕边缘产生色带，干扰色键判定。
func (g *ArkPetImageGenerator) edit(ctx context.Context, input []byte, prompt string) ([]byte, error) {
	mime := http.DetectContentType(input)
	if mime != "image/png" && mime != "image/jpeg" {
		return nil, fmt.Errorf("参考图必须为 PNG/JPEG")
	}
	payload := map[string]any{
		"model":           g.model,
		"prompt":          prompt,
		"image":           "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(input),
		"response_format": "url",
		"size":            arkImageSize,
		"output_format":   "png",
		"stream":          false,
		"watermark":       false,
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
		return nil, fmt.Errorf("Seedream 官方接口请求失败或超时，请稍后重试")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, (32<<20)+1))
	if err != nil || len(data) > 32<<20 {
		return nil, fmt.Errorf("Seedream 官方接口返回过大或读取失败")
	}
	if resp.StatusCode != http.StatusOK {
		// 绝不把上游响应体、请求头或密钥透传给客户端/日志。
		var upstream struct {
			Error struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		_ = json.Unmarshal(data, &upstream)
		code, msg := upstream.Error.Code, upstream.Error.Message
		switch {
		case resp.StatusCode == 400 && (strings.Contains(msg, "at least") || strings.Contains(msg, "pixel") || strings.Contains(code, "InvalidParameter")):
			return nil, fmt.Errorf("Seedream 官方拒绝生成参数（HTTP 400）：请检查分辨率是否达到模型下限（建议 2K）及输入格式；这不一定是照片内容问题")
		case resp.StatusCode == 401 || resp.StatusCode == 403:
			return nil, fmt.Errorf("Seedream 官方鉴权或模型访问失败，请联系管理员检查 ARK API Key 与模型开通")
		case resp.StatusCode == 404:
			return nil, fmt.Errorf("Seedream 官方找不到指定模型或推理接入点，请联系管理员核对 Model ID")
		case resp.StatusCode == 429:
			return nil, fmt.Errorf("Seedream 官方限流或余额不足，请稍后重试")
		case strings.Contains(code, "Sensitive") || strings.Contains(code, "Audit"):
			return nil, fmt.Errorf("Seedream 官方判定输入或输出内容不合规，请更换参考图或提示词")
		default:
			return nil, fmt.Errorf("Seedream 官方图片生成失败（HTTP %d），请稍后重试或联系管理员检查接口配置", resp.StatusCode)
		}
	}
	var out struct {
		Data []struct {
			B64 string `json:"b64_json"`
			URL string `json:"url"`
		} `json:"data"`
	}
	if json.Unmarshal(data, &out) != nil || len(out.Data) == 0 {
		return nil, fmt.Errorf("Seedream 官方图片响应无效")
	}
	if out.Data[0].B64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(out.Data[0].B64)
		if err != nil || len(decoded) == 0 {
			return nil, fmt.Errorf("Seedream 官方图片响应无效")
		}
		return decoded, nil
	}
	if out.Data[0].URL == "" {
		return nil, fmt.Errorf("Seedream 官方未返回图片内容")
	}
	// 兜底：个别模型忽略 response_format 只给 URL，则直接拉取（服务器可直连对象存储）。
	return g.download(ctx, out.Data[0].URL)
}

// download 拉取官方返回的图片 URL，限制体积防止解压炸弹式超大响应拖垮服务。
func (g *ArkPetImageGenerator) download(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("Seedream 官方图片地址无效")
	}
	resp, err := g.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Seedream 官方图片下载失败，请稍后重试")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Seedream 官方图片下载失败（HTTP %d）", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (32<<20)+1))
	if err != nil || len(data) == 0 || len(data) > 32<<20 {
		return nil, fmt.Errorf("Seedream 官方图片过大或下载失败")
	}
	return data, nil
}
