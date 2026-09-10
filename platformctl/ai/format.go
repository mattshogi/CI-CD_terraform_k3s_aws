package ai

import (
	"fmt"
	"strings"

	"github.com/mattshogi/CI-CD_terraform_k3s_aws/platformctl/core"
)

// DeploySummary is the set of facts summarized after a deploy.
type DeploySummary struct {
	RunID     string  `json:"run_id"`
	Image     string  `json:"image"`
	Endpoint  string  `json:"endpoint"`
	Reachable bool    `json:"reachable"`
	HAMode    bool    `json:"ha_mode"`
	CostCents float64 `json:"cost_cents"`
}

// FormatFindings renders a deterministic, ranked findings summary. This is the
// fallback the AI provider improves on, and it is what ships when AI is off.
func FormatFindings(t core.TriageResult) string {
	if t.Total == 0 {
		return "No security findings."
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Security findings: %d total", t.Total)
	for _, sev := range []string{"CRITICAL", "HIGH", "MEDIUM", "LOW"} {
		if n := t.Counts[sev]; n > 0 {
			fmt.Fprintf(&b, ", %d %s", n, sev)
		}
	}
	b.WriteString(".\n")
	max := len(t.Findings)
	if max > 10 {
		max = 10
	}
	for _, f := range t.Findings[:max] {
		fmt.Fprintf(&b, "- [%s] %s (%s)", f.Severity, f.ID, f.Target)
		if f.Fix != "" {
			fmt.Fprintf(&b, " -> %s", f.Fix)
		}
		b.WriteString("\n")
	}
	if len(t.Findings) > max {
		fmt.Fprintf(&b, "...and %d more.\n", len(t.Findings)-max)
	}
	return b.String()
}

// FormatDiagnosis renders a deterministic failure explanation.
func FormatDiagnosis(d core.Diagnosis) string {
	return fmt.Sprintf("Classification: %s\nRoot cause: %s\nSuggested next step: %s",
		d.Classification, d.RootCause, d.Suggestion)
}

// FormatDeploy renders a deterministic deploy summary.
func FormatDeploy(s DeploySummary) string {
	health := "reachable"
	if !s.Reachable {
		health = "not reachable"
	}
	topo := "single-node"
	if s.HAMode {
		topo = "HA (3 servers)"
	}
	return fmt.Sprintf("Deployed %s as run %s (%s). Endpoint %s is %s. Estimated cost %.2f cents.",
		s.Image, s.RunID, topo, s.Endpoint, health, s.CostCents)
}
