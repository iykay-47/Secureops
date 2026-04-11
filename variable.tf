variable "policy_path" {
  description = "Path to create a policy"
  type        = string
  default     = "/"
}

variable "tags" {
  description = "Default tags"
  type        = map(string)
  default = {
    "Environment" = "Dev"
    "ManagedBy"   = "Terraform"
    "Project"     = "Secure-data-Ops"
  }
}

variable "environment" {
  description = "Environment to deploy infra"
  type        = string
  default     = "dev"
}
variable "project_name" {
  description = "Project name to serve as prefix"
  type        = string
  default     = "secure-data-pipeline"
}

variable "alert_emails" {
  description = "Emails subscribed to SNS topic"
  type        = list(string)
  default     = ["ikjnjoku@gmail.com"]
}

variable "cpu_threshold_percent" {
  description = "value"
  type        = number
  default     = 65
}

variable "s3_4xx_threshold" {
  description = "Amount of error attempts on a bucket"
  type        = number
  default     = 5
}

variable "region" {
  description = "defvalueault region"
  type        = string
  default     = "us-east-2"
}

variable "ami_id" {
  description = "custom ami id"
  type        = string
  default     = null
}

variable "ssh_cidr" {
  description = "Cidr ange for acceptiong ssh into instance"
  type        = string
  default     = "0.0.0.0/0" # Replcae with your personal ip address or range
}

variable "key_name" {
  description = "key_name for ssh access to instance"
  type        = string
  default     = "your-key-name"
}

variable "retention_days" {
  description = "Log group amount of retention days"
  type = number
  default = 7 #Set according to Policy requirements
}

variable "kms_key_arn" {
  description = "Arn for kms key"
  type = string
  default = null
}