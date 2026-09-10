package core

import (
	"context"
	"strings"
)

// TriageImage runs Trivy against an image and triages the JSON. The current CI
// emits SARIF, not a JSON artifact, so tools run trivy on demand rather than
// depending on a CI file that is not there.
func (e *Engine) TriageImage(ctx context.Context, imageRef string) (TriageResult, error) {
	res, err := e.Runner.Run(ctx, Command{
		Name: "trivy",
		Args: []string{"image", "--format", "json", "--quiet",
			"--severity", "CRITICAL,HIGH,MEDIUM", "--ignore-unfixed", imageRef},
	})
	if err != nil {
		return TriageResult{}, err
	}
	return TriageSecurityFindings(strings.NewReader(res.Stdout))
}
