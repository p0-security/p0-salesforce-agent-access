terraform {
  required_version = ">= 1.4"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}

locals {
  source_files = sort(concat(
    tolist(fileset(path.module, "force-app/**")),
    tolist(fileset(path.module, "org-setup/**")),
    ["setup.sh", "org-values.sh"],
  ))
}

# Runs on the machine that runs Terraform, which needs the Salesforce CLI (sf),
# jq, and an admin login to the org.
resource "terraform_data" "package" {
  triggers_replace = {
    source               = sha256(join("", [for f in local.source_files : filesha256("${path.module}/${f}")]))
    target_org           = var.target_org
    gateway_issuer       = var.gateway_issuer
    provisioner_username = var.provisioner_username
    handler_username     = var.handler_username
    contact_email        = var.contact_email
  }

  provisioner "local-exec" {
    command = "\"${path.module}/setup.sh\" --target-org \"$TARGET_ORG\" --gateway-issuer \"$GATEWAY_ISSUER\" --provisioner-username \"$PROVISIONER_USERNAME\" --handler-username \"$HANDLER_USERNAME\" --contact-email \"$CONTACT_EMAIL\""
    environment = {
      TARGET_ORG           = var.target_org
      GATEWAY_ISSUER       = var.gateway_issuer
      PROVISIONER_USERNAME = var.provisioner_username
      HANDLER_USERNAME     = var.handler_username
      CONTACT_EMAIL        = var.contact_email
    }
  }
}

data "external" "org" {
  program = ["bash", "${path.module}/org-values.sh"]
  query   = { target_org = var.target_org }

  depends_on = [terraform_data.package]
}
