package core

import (
	"encoding/json"
	"io"
	"sort"
)

// Finding is one deduped, ranked security issue.
type Finding struct {
	ID       string `json:"id"`
	Severity string `json:"severity"`
	Title    string `json:"title"`
	Target   string `json:"target"`
	Package  string `json:"package,omitempty"`
	Fix      string `json:"fix,omitempty"`
}

// TriageResult is the ranked output of triage_security_findings.
type TriageResult struct {
	Findings []Finding      `json:"findings"`
	Counts   map[string]int `json:"counts"`
	Total    int            `json:"total"`
}

// trivyReport matches the shape of `trivy --format json` for both image
// (Vulnerabilities) and config (Misconfigurations) scans.
type trivyReport struct {
	Results []struct {
		Target          string `json:"Target"`
		Vulnerabilities []struct {
			VulnerabilityID  string `json:"VulnerabilityID"`
			PkgName          string `json:"PkgName"`
			InstalledVersion string `json:"InstalledVersion"`
			FixedVersion     string `json:"FixedVersion"`
			Severity         string `json:"Severity"`
			Title            string `json:"Title"`
		} `json:"Vulnerabilities"`
		Misconfigurations []struct {
			ID         string `json:"ID"`
			Title      string `json:"Title"`
			Severity   string `json:"Severity"`
			Resolution string `json:"Resolution"`
		} `json:"Misconfigurations"`
	} `json:"Results"`
}

var severityRank = map[string]int{
	"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "UNKNOWN": 4,
}

func rankOf(sev string) int {
	if r, ok := severityRank[sev]; ok {
		return r
	}
	return 5
}

// TriageSecurityFindings parses a Trivy JSON report into ranked, deduped,
// actionable findings.
func TriageSecurityFindings(r io.Reader) (TriageResult, error) {
	var rep trivyReport
	if err := json.NewDecoder(r).Decode(&rep); err != nil {
		return TriageResult{}, err
	}
	seen := map[string]bool{}
	var out []Finding
	counts := map[string]int{}
	add := func(f Finding) {
		key := f.ID + "|" + f.Target
		if seen[key] {
			return
		}
		seen[key] = true
		out = append(out, f)
		counts[f.Severity]++
	}
	for _, res := range rep.Results {
		for _, v := range res.Vulnerabilities {
			fix := v.FixedVersion
			if fix != "" {
				fix = "upgrade to " + fix
			}
			add(Finding{
				ID: v.VulnerabilityID, Severity: v.Severity, Title: v.Title,
				Target: res.Target, Package: v.PkgName + " " + v.InstalledVersion, Fix: fix,
			})
		}
		for _, m := range res.Misconfigurations {
			add(Finding{
				ID: m.ID, Severity: m.Severity, Title: m.Title,
				Target: res.Target, Fix: m.Resolution,
			})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if rankOf(out[i].Severity) != rankOf(out[j].Severity) {
			return rankOf(out[i].Severity) < rankOf(out[j].Severity)
		}
		return out[i].ID < out[j].ID
	})
	return TriageResult{Findings: out, Counts: counts, Total: len(out)}, nil
}
