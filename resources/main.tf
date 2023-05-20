terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    }
  }
}

variable "lambda_pkg" {
  type        = string
  description = "The relative path to the lambda wait_queues package"
  default     = "../wait_queues"
}

variable "root_dir" {
  type        = string
  description = "The repository root folder"
  default     = ".."
}



resource "aws_sqs_queue" "test_queue" {
  name                        = "test-queue"
  delay_seconds               = 0
  max_message_size            = 4096
  message_retention_seconds   = 86400
  visibility_timeout_seconds  = 30
  receive_wait_time_seconds   = 0
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.test_dl_queue.arn
    maxReceiveCount     = 3
  })
  tags = {
    Environment = "test"
  }
}

resource "aws_sqs_queue" "test_dl_queue" {
  name                        = "test-dl-queue"
  message_retention_seconds   = 86400
  tags = {
    Environment = "test"
    Type = "DLQueue"
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "test_dl_queue" {
  queue_url = aws_sqs_queue.test_dl_queue.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.test_queue.arn]
  })
}

resource "aws_sqs_queue" "test_wait_queue" {
  name                        = "test-wait-queue"
  delay_seconds               = 30
  max_message_size            = 4096
  message_retention_seconds   = 86400
  visibility_timeout_seconds  = 30
  receive_wait_time_seconds   = 0
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.test_wait_dl_queue.arn
    maxReceiveCount     = 10
  })
  tags = {
    Environment = "test"
    Type = "WaitQueue"
  }
}

resource "aws_sqs_queue" "test_wait_dl_queue" {
  name                        = "test-wait-dl-queue"
  message_retention_seconds   = 86400
  tags = {
    Environment = "test"
    Type = "WaitDLQueue"
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "test_wait_dl_queue" {
  queue_url = aws_sqs_queue.test_wait_dl_queue.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.test_wait_queue.arn]
  })
}

data "aws_iam_policy_document" "test_wait_queue_policy_doc" {
  statement {
    sid    = "First"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.test_wait_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_lambda_function.test_lambda.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "test_wait_queue_policy" {
  queue_url = aws_sqs_queue.test_wait_queue.id
  policy    = data.aws_iam_policy_document.test_wait_queue_policy_doc.json
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "sqs-message-listener-exec-role"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "sqs-message-listener-policy"
  description = "test policy for sqs-message-listener lambda"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "sqs:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "attach_policy_for_lambda" {
  name       = "sqs-message-listener-policy-attachment"
  roles      = [aws_iam_role.iam_for_lambda.name]
  policy_arn = aws_iam_policy.lambda_policy.arn
}


resource "null_resource" "install_dependencies" {
  provisioner "local-exec" {
    command = "pip install -r ${var.root_dir}/requirements.txt -t ${var.lambda_pkg}/site-packages/"
  }

  triggers = {
    dependencies_versions = filemd5("${var.root_dir}/requirements.txt")
  }
}

data "archive_file" "lambda_archive" {
  type        = "zip"
  depends_on = [null_resource.install_dependencies]
  excludes   = [
    "__pycache__", ".pytest_cache"
  ]
  source_dir = var.lambda_pkg
  output_path = "${var.root_dir}/lambda_function.zip"
}

resource "aws_lambda_function" "test_lambda" {
    filename      = "${var.root_dir}/lambda_function.zip"
  function_name = "sqs-message-listener"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "lambda_function.handler"

  source_code_hash = data.archive_file.lambda_archive.output_base64sha256
  timeout = 5
  runtime = "python3.9"

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "sqs-message-listener"
      LOG_LEVEL = "INFO"
      PYTHONPATH = "site-packages"
    }
  }
}

resource "aws_cloudwatch_log_group" "test_lambda_log_group" {
  name = "/aws/lambda/sqs-message-listener"
  retention_in_days = 5
  tags = {
    Environment = "test"
    Application = "Wait Queues"
  }
}

resource "aws_lambda_event_source_mapping" "test_queue_to_lambda" {
  event_source_arn = aws_sqs_queue.test_queue.arn
  function_name    = aws_lambda_function.test_lambda.arn
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_event_source_mapping" "test_wait_queue_to_lambda" {
  event_source_arn = aws_sqs_queue.test_wait_queue.arn
  function_name    = aws_lambda_function.test_lambda.arn
  function_response_types = ["ReportBatchItemFailures"]
}
