output "ip_address" {
  value = aws_instance.data_pipeline.public_ip
}

output "instance_profile_arn" {
  value = aws_iam_instance_profile.ec2_instance_profile.arn
}

output "ec2_assume_role_arn" {
  value = aws_iam_policy.ec2-role.arn
}

output "assumed_arn" {
  value = data.aws_caller_identity.current.arn
}