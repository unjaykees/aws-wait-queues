# AWS Wait Queues

## Prerequisites

1. Install Terraform cli. See: https://developer.hashicorp.com/terraform/downloads

2. Install AWS cli. See: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

3. Configure AWS credentials. See: https://registry.terraform.io/providers/hashicorp/aws/latest/docs#environment-variables

4. The following tools might also be useful:
   * [JQ](https://stedolan.github.io/jq/download/)
   * [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)


## Deploy 

1. Run the following command to generate terraform execution plan:
```bash
terraform -chdir=resources plan --out=tf_main.plan
```

2. Run the following command to deploy AWS resources based on plan:
```bash
terraform -chdir=resources apply tf_main.plan
```

## Test

You can test this example by adapting and sending following message to the SQS `test-queue`.
You can also use AWS SQS Web Console and send message directly by navigating to `Send and Receive Messages` screen. 
```bash
aws sqs send-message \
--queue-url $(aws sqs get-queue-url --queue-name test-queue | jq -r '.QueueUrl') \
--message-body "{\"sourceId\": \"#123abc\", \"delay\": 120, \"createTimestamp\": \"[YYYY-mm-dd HH:MM:SS]\", \"waitQueueName\": \"test-wait-queue\"}"
```
