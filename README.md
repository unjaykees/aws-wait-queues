# AWS Wait Queues
This project is an example of implementing message wait queues that can be used
for controlling velocity of message consumption off a queue.
This example uses AWS SQS Queues and Lambda Function as solution components in AWS cloud.

Read more: https://medium.com/@unjaykees/message-wait-queues-874738d066a6

## Prerequisites

1. Install Terraform cli. See: https://developer.hashicorp.com/terraform/downloads

2. Install AWS cli. See: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

3. Configure AWS credentials. See: https://registry.terraform.io/providers/hashicorp/aws/latest/docs#environment-variables
    

4. The following tools might also be useful:
   * [JQ](https://stedolan.github.io/jq/download/)
   * [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)


## Deploy 

Running this example requires necessary permissions for the user or role that will be making the deployment.
Please configure your IAM policies to add permissions necessary to deploy the resources from this example.

1. Run the following command to generate terraform execution plan:
```bash
terraform -chdir=resources plan --out=tf_main.plan
```

2. Run the following command to deploy AWS resources based on plan:
```bash
terraform -chdir=resources apply tf_main.plan
```

**NOTE**
By deploying this example, you might incur some costs on your AWS account (especially if you're not on free tier anymore).
Be sure to monitor the costs and remove the resources if costs are reaching your limit.

## Test

You can test this example by adapting and sending following message to the SQS `test-queue`.
You can also use AWS SQS Web Console and send message directly by navigating to `Send and Receive Messages` screen. 

```bash
aws sqs send-message \
--queue-url $(aws sqs get-queue-url --queue-name test-queue | jq -r '.QueueUrl') \
--message-body "{\"sourceId\": \"#123abc\", \"delay\": 120, \"createTimestamp\": \"[YYYY-mm-dd HH:MM:SS]\", \"waitQueueName\": \"test-wait-queue\"}"
```

## Remove

You can run this command to destroy previously created resources:

```bash
terraform -chdir=resources apply -destroy
```
