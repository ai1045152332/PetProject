package service

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"
)

// Style and poses adapted from skills/meijing-pet-prompts/references/prompts.md.
// The uploaded photo remains the identity anchor; never use the archive's sample cat/expired URL.
//
//go:embed prompts/pet_states_v3.json
var petStatePromptJSON []byte

// petDefaultComposition 是通用取景约束：全身完整、居中、四周留白不得裁切。
// 个别状态（如 hide 躲藏）可在 JSON 中用 composition 覆盖，只画探出来的部分。
const petDefaultComposition = "全身完整可见，居中摆放，头顶、耳尖、爪子和尾巴四周留充足空白。身体和道具均不得被裁切。"

type petStatePrompt struct {
	Name        string `json:"name"`
	Pose        string `json:"pose"`
	Motion      string `json:"motion"`
	Composition string `json:"composition"`
}

func petPromptsForState(state string) (string, string, error) {
	if state == "" {
		state = "idel"
	} // Legacy shared-image uploads retain relaxed idle behavior.
	var states map[string]petStatePrompt
	if err := json.Unmarshal(petStatePromptJSON, &states); err != nil {
		return "", "", fmt.Errorf("宠物状态 Prompt 配置无效")
	}
	spec, ok := states[state]
	if !ok || spec.Name == "" || spec.Pose == "" || spec.Motion == "" {
		return "", "", fmt.Errorf("不支持的宠物生成状态：%s", state)
	}
	composition := spec.Composition
	if composition == "" {
		composition = petDefaultComposition
	}
	replace := strings.NewReplacer("{{STATE_KEY}}", state, "{{STATE_NAME}}", spec.Name, "{{STATE_POSE}}", spec.Pose, "{{STATE_MOTION}}", spec.Motion, "{{STATE_COMPOSITION}}", composition)
	return replace.Replace(petPortraitPrompt), replace.Replace(petAnimationPrompt), nil
}
