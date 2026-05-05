variable "thing_name" {
  description = "IoT Thing name. Must match the device_id used in MQTT client ID and topic prefix."
  type        = string
}

variable "certificate_arn" {
  description = "ARN of the pre-provisioned X.509 certificate to attach to this Thing. Null skips attachment."
  type        = string
  default     = null
}

variable "topic_prefix" {
  description = "MQTT topic prefix for this domain (e.g. dt/coldchain). Device may publish to {topic_prefix}/{thing_name}/*."
  type        = string
}

variable "name_prefix" {
  description = "Resource naming prefix from the root module (project-environment)."
  type        = string
}

variable "tags" {
  description = "Tags to apply to the IoT Thing and policy."
  type        = map(string)
  default     = {}
}
