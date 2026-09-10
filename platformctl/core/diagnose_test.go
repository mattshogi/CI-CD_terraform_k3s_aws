package core

import (
	"os"
	"testing"
)

func TestExplainLastFailure(t *testing.T) {
	log, err := os.ReadFile("../testdata/failing-run.log")
	if err != nil {
		t.Fatal(err)
	}
	d := ExplainLastFailure(string(log))
	if d.Classification != "vpc-limit" {
		t.Errorf("expected vpc-limit, got %q", d.Classification)
	}
	if d.Suggestion == "" || d.Evidence == "" {
		t.Errorf("expected suggestion and evidence, got %+v", d)
	}
}

func TestExplainLastFailureUnknown(t *testing.T) {
	d := ExplainLastFailure("everything is fine here")
	if d.Classification != "unknown" {
		t.Errorf("expected unknown, got %q", d.Classification)
	}
}
