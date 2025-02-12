resource "aws_sfn_state_machine" "mrpid_publisher_sfn" {
  name = "mrpid-publisher-sfn-${var.pce_instance_id}"

  role_arn = aws_iam_role.mrpid_publisher_sfn_role.arn

  type = "STANDARD"

  definition = <<EOF
  {
  }
  EOF

  logging_configuration {
    log_destination = "${aws_cloudwatch_log_group.mrpid_publisher_sfn_log_group.arn}:*"
    include_execution_data = true
    level = "ALL"
  }
}
