package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPetStatePromptRequirements(t *testing.T) {
	for state, required := range map[string][]string{
		"idel":  {"四脚自然站立", "尾尖轻轻摆动"},
		"sleep": {"蜷缩", "双眼闭合", "不醒来"},
		"pet":   {"眯着眼睛", "绝对不出现人的手"},
		"focus": {"笔记本电脑", "交替轻轻打字"},
	} {
		t.Run(state, func(t *testing.T) {
			portrait, animation, err := petPromptsForState(state)
			if err != nil {
				t.Fatal(err)
			}
			for _, prompt := range []string{portrait, animation} {
				if strings.Contains(prompt, "{{") || !strings.Contains(prompt, state) || !strings.Contains(prompt, "3头身Q版") {
					t.Fatal("unresolved state/style")
				}
				if !strings.Contains(prompt, "不要地面阴影") || !strings.Contains(prompt, "人的手") {
					t.Fatal("missing reference constraints")
				}
			}
			combined := portrait + animation
			for _, text := range required {
				if !strings.Contains(combined, text) {
					t.Errorf("%s missing %s", state, text)
				}
			}
			if !strings.Contains(animation, "4列×4行") || !strings.Contains(animation, "16帧") {
				t.Fatal("GIF grid contract lost")
			}
			if state != "focus" && strings.Contains(portrait, "一台小巧简洁的笔记本电脑") {
				t.Fatal("work prop leaked into another state")
			}
			if strings.Contains(combined, "银渐层") || strings.Contains(combined, "s3plus") {
				t.Fatal("archive sample replaced uploaded pet identity")
			}
		})
	}
	idlePortrait, idleAnimation, _ := petPromptsForState("idel")
	legacyPortrait, legacyAnimation, err := petPromptsForState("")
	if err != nil || idlePortrait != legacyPortrait || idleAnimation != legacyAnimation {
		t.Fatal("legacy state must default to idle")
	}
	if _, _, err = petPromptsForState("invalid"); err == nil {
		t.Fatal("invalid state accepted")
	}
	// 提醒状态已合并进专注，提示词模板不再提供 warn。
	if _, _, err = petPromptsForState("warn"); err == nil {
		t.Fatal("removed legacy warn state still has prompts")
	}
}
func TestEveryStateReachesBothModelRequests(t *testing.T) {
	fixture := base64.StdEncoding.EncodeToString(testPetSheet(t))
	for _, state := range []string{"focus", "idel", "sleep", "pet"} {
		t.Run(state, func(t *testing.T) {
			portrait, animation, _ := petPromptsForState(state)
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				var body struct {
					Prompt string `json:"prompt"`
				}
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				if calls == 1 {
					if body.Prompt != portrait {
						t.Error("portrait got wrong state prompt")
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"b64_json": fixture, "media_type": "image/png"}}})
				} else {
					if body.Prompt != animation {
						t.Error("animation got wrong state prompt")
					}
					// End the mock here: no need to encode a GIF for every prompt-routing check.
					w.WriteHeader(500)
				}
			}))
			defer server.Close()
			generator := NewOpenRouterPetImageGenerator("test-key", "openai/gpt-image-2.5-sunburst")
			generator.endpoint = server.URL
			_, err := generator.Generate(context.Background(), testImage(t, "png"), state, func(string) {})
			if petFrameModeAnimated {
				// Animated mode must reach both the portrait and the animation request with per-state prompts.
				if err == nil || calls != 2 {
					t.Fatal("two-stage state routing not exercised")
				}
			} else if err != nil || calls != 1 {
				// Single-frame mode issues only the portrait request, which must carry the state prompt.
				t.Fatalf("single-frame routing: calls=%d err=%v", calls, err)
			}
		})
	}
}
func TestUploadAndRetryPassTargetStateToGenerator(t *testing.T) {
	svc := newImageTestService(t, t.TempDir())
	seen := make(chan string, 6)
	svc.SetGenerator(testPetGenerator(func(_ context.Context, _ []byte, state string, _ func(string)) ([]byte, error) {
		seen <- state
		return testPetGIF(t), nil
	}))
	for _, state := range []string{"focus", "idel", "pet"} {
		lib, err := svc.Upload("A", petTestCode, state+".png", testImage(t, "png"), state)
		if err != nil {
			t.Fatal(err)
		}
		lib = awaitPet(t, svc, "A", lib.Images[0].ID)
		if got := <-seen; got != state {
			t.Fatalf("generator got %s for %s", got, state)
		}
		if lib.Images[0].PromptVersion != PetPromptVersion {
			t.Fatal("prompt version not recorded")
		}
	}
	var original []byte
	svc.SetGenerator(testPetGenerator(func(_ context.Context, photo []byte, state string, _ func(string)) ([]byte, error) {
		seen <- state
		original = bytes.Clone(photo)
		return nil, fmt.Errorf("simulated failure")
	}))
	lib, err := svc.Upload("A", petTestCode, "sleep.png", testImage(t, "png"), "sleep")
	if err != nil {
		t.Fatal(err)
	}
	id := lib.Images[0].ID
	_ = awaitPet(t, svc, "A", id)
	if got := <-seen; got != "sleep" {
		t.Fatal("sleep state lost")
	}
	svc.SetGenerator(testPetGenerator(func(_ context.Context, photo []byte, state string, _ func(string)) ([]byte, error) {
		seen <- state
		if !bytes.Equal(photo, original) {
			return nil, fmt.Errorf("retry lost original identity reference")
		}
		return testPetGIF(t), nil
	}))
	if _, err = svc.Retry("A", petTestCode, id, "sleep"); err != nil {
		t.Fatal(err)
	}
	lib = awaitPet(t, svc, "A", id)
	if got := <-seen; got != "sleep" || lib.Images[0].Status != "ready" {
		t.Fatal("retry lost sleep state")
	}
}
