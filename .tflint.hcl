plugin "aws" {
  enabled = true
}

# Exclude experimental modules if needed
ignore_module = ["infra/agents"]

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = false
}
