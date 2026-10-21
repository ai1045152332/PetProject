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

type petStatePrompt struct {
	Name   string `json:"name"`
	Pose   string `json:"pose"`
	Motion string `json:"motion"`
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
	replace := strings.NewReplacer("{{STATE_KEY}}", state, "{{STATE_NAME}}", spec.Name, "{{STATE_POSE}}", spec.Pose, "{{STATE_MOTION}}", spec.Motion)
	return replace.Replace(petPortraitPrompt), replace.Replace(petAnimationPrompt), nil
}
