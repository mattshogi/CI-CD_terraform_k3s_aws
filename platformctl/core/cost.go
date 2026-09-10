package core

import "fmt"

// CostEstimate is a rough on-demand cost for an ephemeral run.
type CostEstimate struct {
	InstanceType  string  `json:"instance_type"`
	NodeCount     int     `json:"node_count"`
	Minutes       int     `json:"minutes"`
	InstanceCents float64 `json:"instance_cents"`
	NlbCents      float64 `json:"nlb_cents"`
	TotalCents    float64 `json:"total_cents"`
	Note          string  `json:"note"`
}

// hourlyUSD is approximate on-demand Linux pricing in us-east-1, enough for a
// cents-level estimate. Not a billing source of truth.
var hourlyUSD = map[string]float64{
	"t3.micro":  0.0104,
	"t3.small":  0.0208,
	"t3.medium": 0.0416,
	"t3.large":  0.0832,
}

const nlbHourlyUSD = 0.0225

// EstimateRunCost returns the estimated cost of a run in cents. HA runs use
// three nodes plus a network load balancer.
func EstimateRunCost(instanceType string, haMode bool, minutes int) (CostEstimate, error) {
	price, ok := hourlyUSD[instanceType]
	if !ok {
		return CostEstimate{}, fmt.Errorf("unknown instance type %q", instanceType)
	}
	if minutes < 0 {
		return CostEstimate{}, fmt.Errorf("minutes must be >= 0")
	}
	nodes := 1
	if haMode {
		nodes = 3
	}
	hours := float64(minutes) / 60.0
	instCents := price * float64(nodes) * hours * 100
	nlbCents := 0.0
	if haMode {
		nlbCents = nlbHourlyUSD * hours * 100
	}
	return CostEstimate{
		InstanceType:  instanceType,
		NodeCount:     nodes,
		Minutes:       minutes,
		InstanceCents: round2(instCents),
		NlbCents:      round2(nlbCents),
		TotalCents:    round2(instCents + nlbCents),
		Note:          "on-demand us-east-1 estimate; excludes EBS and data transfer (cents-level)",
	}, nil
}
