variable "target_org" {
  description = "Salesforce CLI alias or username of an admin in the org. Log in first with `sf org login web --alias <alias>`."
  type        = string
}

variable "gateway_issuer" {
  description = "URL of your P0 agentic gateway, e.g. https://gateway.example.com"
  type        = string

  validation {
    condition     = startswith(var.gateway_issuer, "https://")
    error_message = "The gateway issuer must be an https URL."
  }
}

variable "provisioner_username" {
  description = "Username of the user that P0's connector signs in as. Give it API access and no admin permissions."
  type        = string
}

variable "handler_username" {
  description = "Username of the user that the token-exchange handler runs as. It must be an admin, and not the provisioner."
  type        = string
}

variable "contact_email" {
  description = "Contact email for the P0 Agent and P0 Provisioner external client apps"
  type        = string
}
