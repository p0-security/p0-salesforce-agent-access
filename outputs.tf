output "full_domain" {
  description = "The org's My Domain host. Enter it as the full domain when you install the org in P0."
  value       = data.external.org.result.full_domain
}

output "provisioner_consumer_key" {
  description = "Consumer key of the P0 Provisioner app"
  value       = data.external.org.result.provisioner_consumer_key
}

output "agent_consumer_key" {
  description = "Consumer key of the P0 Agent app"
  value       = data.external.org.result.agent_consumer_key
}
