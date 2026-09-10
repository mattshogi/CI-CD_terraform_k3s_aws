package core

import "testing"

func TestEstimateRunCost(t *testing.T) {
	single, err := EstimateRunCost("t3.small", false, 60)
	if err != nil {
		t.Fatalf("single: %v", err)
	}
	if single.NodeCount != 1 || single.NlbCents != 0 {
		t.Errorf("single node/nlb wrong: %+v", single)
	}
	if single.TotalCents <= 0 {
		t.Errorf("expected positive cost, got %v", single.TotalCents)
	}

	ha, err := EstimateRunCost("t3.medium", true, 60)
	if err != nil {
		t.Fatalf("ha: %v", err)
	}
	if ha.NodeCount != 3 || ha.NlbCents <= 0 {
		t.Errorf("ha node/nlb wrong: %+v", ha)
	}
	if ha.TotalCents <= single.TotalCents {
		t.Errorf("ha (%v) should cost more than single (%v)", ha.TotalCents, single.TotalCents)
	}

	if _, err := EstimateRunCost("m5.24xlarge", false, 60); err == nil {
		t.Error("expected error for unknown instance type")
	}
}
