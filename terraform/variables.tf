# Fill these via terraform.tfvars / secrets.auto.tfvars (see *.example) or TF_VAR_* env vars.
# No secret has a default — terraform will prompt if one is missing.

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "domain" {
  description = "Root DNS zone managed by this stack (Cloudflare)."
  type        = string
  default     = "example.com"
}

variable "location" {
  # Primary EU DC. Per-resource placement is set in main.tf (locals.locations spreads nodes across
  # fsn1/nbg1/hel1); this default is the fallback region. eu-central locations: fsn1, nbg1, hel1.
  default = "fsn1"
}

variable "os_type" {
  default = "ubuntu-24.04"
}

