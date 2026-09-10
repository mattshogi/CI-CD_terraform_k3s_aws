package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// BYOK is a bring-your-own-key provider for Anthropic (default) or OpenAI. The
// key comes from PLATFORMCTL_AI_API_KEY and is never logged or committed. With
// no key set, Summarize returns the fallback and makes no request.
type BYOK struct {
	apiKey string
	vendor string // "anthropic" | "openai"
	model  string
	client *http.Client
}

// NewBYOK reads configuration from the environment.
func NewBYOK() BYOK {
	return BYOK{
		apiKey: os.Getenv("PLATFORMCTL_AI_API_KEY"),
		vendor: envOr("PLATFORMCTL_AI_PROVIDER", "anthropic"),
		model:  envOr("PLATFORMCTL_AI_MODEL", "claude-sonnet-5"),
		client: &http.Client{Timeout: 30 * time.Second},
	}
}

// Name identifies the provider.
func (BYOK) Name() string { return "byok" }

// Summarize calls the configured vendor, or returns the fallback if no key is
// set. The Cached wrapper turns any returned error into the fallback, so this
// never fails a pipeline.
func (b BYOK) Summarize(ctx context.Context, req Request) (string, error) {
	if b.apiKey == "" {
		return req.Fallback, nil
	}
	if b.vendor == "openai" {
		return b.openai(ctx, req)
	}
	return b.anthropic(ctx, req)
}

func (b BYOK) anthropic(ctx context.Context, req Request) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model":      b.model,
		"max_tokens": 1024,
		"system":     systemFor(req.Task),
		"messages":   []map[string]string{{"role": "user", "content": req.Prompt}},
	})
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.anthropic.com/v1/messages", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("content-type", "application/json")
	httpReq.Header.Set("x-api-key", b.apiKey)
	httpReq.Header.Set("anthropic-version", "2023-06-01")
	resp, err := b.client.Do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("anthropic status %d", resp.StatusCode)
	}
	var out struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Content) == 0 {
		return "", fmt.Errorf("anthropic: empty response")
	}
	return out.Content[0].Text, nil
}

func (b BYOK) openai(ctx context.Context, req Request) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model":      b.model,
		"max_tokens": 1024,
		"messages": []map[string]string{
			{"role": "system", "content": systemFor(req.Task)},
			{"role": "user", "content": req.Prompt},
		},
	})
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.openai.com/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("content-type", "application/json")
	httpReq.Header.Set("authorization", "Bearer "+b.apiKey)
	resp, err := b.client.Do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("openai status %d", resp.StatusCode)
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Choices) == 0 {
		return "", fmt.Errorf("openai: empty response")
	}
	return out.Choices[0].Message.Content, nil
}
