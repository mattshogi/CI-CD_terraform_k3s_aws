package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// Budget ceilings. Input is truncated before the call; output is capped after.
// These bound token spend per run to a documented, predictable ceiling.
const (
	DefaultMaxInputChars  = 12000
	DefaultMaxOutputChars = 4000
)

// Truncate caps s to max characters with a marker.
func Truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "\n...[truncated]"
}

// diskCache is a content-hash cache so identical requests are never paid for
// twice.
type diskCache struct{ dir string }

func newCache() diskCache {
	dir := os.Getenv("PLATFORMCTL_AI_CACHE")
	if dir == "" {
		dir = filepath.Join(os.TempDir(), "platformctl-ai-cache")
	}
	return diskCache{dir: dir}
}

func (c diskCache) key(req Request) string {
	h := sha256.Sum256([]byte(req.Task + "\x00" + req.Prompt))
	return hex.EncodeToString(h[:])
}

func (c diskCache) get(k string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(c.dir, k))
	if err != nil {
		return "", false
	}
	return string(b), true
}

func (c diskCache) put(k, v string) {
	_ = os.MkdirAll(c.dir, 0o755)
	_ = os.WriteFile(filepath.Join(c.dir, k), []byte(v), 0o644)
}

// Cached wraps a provider with input truncation, output capping, a content
// cache, and the fall-back-on-error guarantee.
type Cached struct {
	Inner  Provider
	cache  diskCache
	MaxIn  int
	MaxOut int
}

// WithBudget applies the default budget and cache to a provider.
func WithBudget(p Provider) Cached {
	return Cached{Inner: p, cache: newCache(), MaxIn: DefaultMaxInputChars, MaxOut: DefaultMaxOutputChars}
}

// Name identifies the wrapped provider.
func (c Cached) Name() string { return c.Inner.Name() }

// Summarize truncates the input, serves from cache when possible, calls the
// inner provider, caps the output, and returns the deterministic fallback on
// any error.
func (c Cached) Summarize(ctx context.Context, req Request) (string, error) {
	req.Prompt = Truncate(req.Prompt, c.MaxIn)
	if c.Inner.Name() == "none" {
		return c.Inner.Summarize(ctx, req)
	}
	k := c.cache.key(req)
	if v, ok := c.cache.get(k); ok {
		return v, nil
	}
	out, err := c.Inner.Summarize(ctx, req)
	if err != nil {
		return req.Fallback, nil
	}
	out = Truncate(out, c.MaxOut)
	c.cache.put(k, out)
	return out, nil
}
