package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Local is a $0 provider backed by a local Ollama server, for anyone who wants
// AI features without a paid key. On any error it returns the fallback (via the
// Cached wrapper), so a missing or stopped Ollama never breaks a run.
type Local struct {
	url    string
	model  string
	client *http.Client
}

// NewLocal reads the Ollama URL and model from the environment.
func NewLocal() Local {
	return Local{
		url:    envOr("PLATFORMCTL_AI_OLLAMA_URL", "http://localhost:11434"),
		model:  envOr("PLATFORMCTL_AI_MODEL", "llama3.2"),
		client: &http.Client{Timeout: 60 * time.Second},
	}
}

// Name identifies the provider.
func (Local) Name() string { return "local" }

// Summarize calls the local Ollama generate endpoint.
func (l Local) Summarize(ctx context.Context, req Request) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"model":  l.model,
		"system": systemFor(req.Task),
		"prompt": req.Prompt,
		"stream": false,
	})
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, l.url+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("content-type", "application/json")
	resp, err := l.client.Do(httpReq)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("ollama status %d", resp.StatusCode)
	}
	var out struct {
		Response string `json:"response"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || out.Response == "" {
		return "", fmt.Errorf("ollama: empty response")
	}
	return out.Response, nil
}
