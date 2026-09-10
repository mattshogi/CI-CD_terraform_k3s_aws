package core

import (
	"os"
	"testing"
)

func TestTriageSecurityFindings(t *testing.T) {
	f, err := os.Open("../testdata/trivy.json")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	res, err := TriageSecurityFindings(f)
	if err != nil {
		t.Fatalf("triage: %v", err)
	}
	// Three unique findings (the duplicate CVE-2024-0001 is deduped).
	if res.Total != 3 {
		t.Fatalf("expected 3 findings, got %d (%+v)", res.Total, res.Findings)
	}
	// Ranked most-severe first.
	if res.Findings[0].Severity != "CRITICAL" {
		t.Errorf("expected CRITICAL first, got %s", res.Findings[0].Severity)
	}
	if res.Counts["CRITICAL"] != 1 || res.Counts["HIGH"] != 1 || res.Counts["MEDIUM"] != 1 {
		t.Errorf("counts wrong: %+v", res.Counts)
	}
	// A fixable vuln surfaces its fix.
	if res.Findings[0].Fix == "" {
		t.Errorf("expected a fix suggestion on the critical finding")
	}
}
