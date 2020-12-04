variable "api-version" {
  description = "IMDS API Version"
  default     = "2019-04-30"
}

variable "auto-deploy-version" {
  description = "Version for automated deployment"
  default     = "Fe"
}

variable "scenario" {
  description = "Deployment Scenario"
  default     = "sap_system"
}

variable "max_timeout" {
  description = "Maximum time allowed to spend for curl"
  default     = 10
}

// Registers the current deployment state with Azure's Metadata Service (IMDS)
resource "null_resource" "IMDS_linux" {
  provisioner "local-exec" {
    command    = "curl --silent --output /dev/null --max-time ${var.max_timeout} -i -H \"Metadata: \"true\"\" -H \"user-agent: SAP AutoDeploy/${var.auto-deploy-version}; scenario=${var.scenario}; deploy-status=Terraform_${var.scenario}\" http://169.254.169.254/metadata/instance?api-version=${var.api-version}"
    on_failure = continue
  }
}

resource "null_resource" "IMDS_windows" {
  provisioner "local-exec" {
    command    = "Invoke-RestMethod -Headers @{\"Metadata\"=\"true\"; \"user-agent\"=\"SAP AutoDeploy/${var.auto-deploy-version}\"; \"scenario\"=\"${var.scenario}_windows\"; \"deploy-status\"=\"Terraform_${var.scenario}\"} -Method GET -NoProxy -Uri http://169.254.169.254/metadata/instance?api-version=${var.api-version}"
    on_failure = continue
  }
}
