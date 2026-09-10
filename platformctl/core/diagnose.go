package core

import (
	"regexp"
	"strings"
)

// Diagnosis is the structured root-cause of a failed run.
type Diagnosis struct {
	Classification string `json:"classification"`
	RootCause      string `json:"root_cause"`
	Suggestion     string `json:"suggestion"`
	Evidence       string `json:"evidence"`
}

// diagnosisRule maps a log signature to a plain-language explanation. These
// mirror the real failure modes this platform has hit, so the rule-based
// diagnosis is genuinely useful before any AI is involved. Stage 2 layers an
// LLM narrative on top of the same matched evidence.
var diagnosisRules = []struct {
	re         *regexp.Regexp
	class      string
	cause      string
	suggestion string
}{
	{regexp.MustCompile(`(?i)VpcLimitExceeded`), "vpc-limit",
		"The account is at its VPC limit, so a new VPC could not be created.",
		"Delete unused VPCs (check for empty leftovers with orphaned NACLs) or reuse one via vpc_id."},
	{regexp.MustCompile(`(?i)(InvalidIAMInstanceProfile|NoSuchEntity)`), "iam-propagation",
		"An IAM instance profile was referenced before it finished propagating.",
		"This is usually transient; the deploy retries once. If it persists, increase the propagation delay."},
	{regexp.MustCompile(`(?i)not supported in your requested Availability Zone`), "az-instance-type",
		"The chosen instance type is not offered in the availability zone the subnet landed in.",
		"The infra pins the subnet to an AZ that offers the type; verify aws_ec2_instance_type_offerings covers your instance_type."},
	{regexp.MustCompile(`(?i)iam:CreateServiceLinkedRole.*elasticloadbalancing`), "elb-slr-missing",
		"The account's ELB service-linked role does not exist yet, which the first load balancer needs.",
		"Apply infra/bootstrap/github-oidc once; it creates the ELB service-linked role."},
	{regexp.MustCompile(`(?i)AccessDenied.*elasticloadbalancing`), "elb-permissions",
		"The deploy role lacks an elasticloadbalancing permission needed for HA mode.",
		"Update and re-apply infra/bootstrap/github-oidc to grant the missing ELB action."},
	{regexp.MustCompile(`(?i)AccessDenied.*ssm:`), "ssm-permissions",
		"The deploy role lacks an SSM permission.",
		"Update and re-apply infra/bootstrap/github-oidc to grant the missing SSM action."},
	{regexp.MustCompile(`(?i)(Throttling|RequestLimitExceeded)`), "throttling",
		"AWS throttled the API calls during apply.",
		"Transient; the deploy retries once. Re-run if it recurs."},
	{regexp.MustCompile(`(?i)ImagePullBackOff`), "image-pull",
		"The app image could not be pulled onto the node.",
		"Check GHCR package visibility is public; the bootstrap falls back to hashicorp/http-echo automatically."},
	{regexp.MustCompile(`(?i)TLS handshake timeout`), "memory-pressure",
		"The kube-apiserver became unreachable, typically memory exhaustion under a stacked flag set.",
		"Use a larger instance (t3.medium for the full flag stack); check free -m over SSM."},
	{regexp.MustCompile(`(?i)DependencyViolation`), "dependency-violation",
		"A resource could not be deleted because another still depends on it.",
		"Transient during teardown; the deploy retries. If manual, remove dependents (ENIs, NACLs) first."},
}

// ExplainLastFailure scans a failed run's log and returns the first matching
// rule's structured diagnosis, or an unknown classification.
func ExplainLastFailure(log string) Diagnosis {
	for _, line := range strings.Split(log, "\n") {
		for _, rule := range diagnosisRules {
			if rule.re.MatchString(line) {
				return Diagnosis{
					Classification: rule.class,
					RootCause:      rule.cause,
					Suggestion:     rule.suggestion,
					Evidence:       Scrub(strings.TrimSpace(line)),
				}
			}
		}
	}
	return Diagnosis{
		Classification: "unknown",
		RootCause:      "No known failure signature matched the log.",
		Suggestion:     "Inspect the full log and the SSM diagnostics artifact; consider explain_last_failure with AI enabled (Stage 2).",
	}
}
