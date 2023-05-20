from datetime import datetime, timedelta
from dataclasses import dataclass
from json import loads as json_loads
from os import getenv as os_getenv
from typing import Any, Dict

from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext
from aws_lambda_powertools.utilities.batch import BatchProcessor, EventType
from aws_lambda_powertools.utilities.data_classes.sqs_event import SQSRecord
import boto3


logger = Logger()


class PrematureException(Exception):
    """ exception raised when message conditional check fails"""
    ...


@dataclass
class SQSRecordWrapper:
    """ decorates and extends SQSRecord """
    record: SQSRecord
    message_attributes = {}

    def __getattr__(self, item):
        return getattr(self.record, item)

    @property
    def queue_name(self) -> str:
        return self.record.event_source_arn.split(':')[-1]

    @property
    def origin_queue_arn(self) -> str:
        if (origin_queue := self.record.message_attributes.get('originQueueARN')) is not None:
            return origin_queue['stringValue']
        return self.record.event_source_arn

    def set_origin_queue_arn(self, queue_arn: str):
        self.message_attributes['originQueueARN'] = {
            'StringValue': queue_arn,
            'DataType': 'String'
        }

    @property
    def origin_message_id(self) -> str:
        if (origin_message_id := self.record.message_attributes.get('originMessageId')) is not None:
            return origin_message_id['stringValue']
        return self.record.message_id

    def set_origin_message_id(self, message_id: str):
        self.message_attributes['originMessageId'] = {
            'StringValue': message_id,
            'DataType': 'String'
        }

    def is_from_wait_queue(self) -> bool:
        return '-wait-' in self.queue_name


class PrematureMessageHandler:
    """ """
    def __init__(self, record: SQSRecord):
        self.message = SQSRecordWrapper(record)
        self.sqs_client = boto3.client('sqs', region_name=os_getenv('REGION_NAME', 'us-east-1'))

    def handle_message(self) -> Dict[str, Any]:
        """ handle incoming premature message, send it to wait queue if it hasn't been re-routed there yet
            otherwise, raise PrematureException to leverage 'ReportBatchItemFailures' functionality
        :raises: PrematureException
        :returns SQS SendMessage response
        """
        logger.info(f"This message originated in {self.message.origin_queue_arn}")

        if self.message.is_from_wait_queue():
            # this message already came from wait queue, allow for exception based retries
            # (wait queue is configured to support multiple retries)
            logger.warning(
                f"Message (origin msg_id={self.message.origin_message_id}) is still in wait condition. "
                f"Will stay on wait queue.."
            )
            raise PrematureException(f"Message (msg_id={self.message.message_id}) cannot be processed yet")

        wait_queue_name = json_loads(self.message.body)['waitQueueName']
        logger.info(
            f"Message (msg_id={self.message.message_id}) is premature "
            f"and will be re-routed to wait queue={wait_queue_name}.."
        )

        self.message.set_origin_queue_arn(self.message.event_source_arn)
        self.message.set_origin_message_id(self.message.message_id)

        # this message will be relayed to wait queue for retries until its condition check passes
        return self.sqs_client.send_message(
            QueueUrl=self.sqs_client.get_queue_url(QueueName=wait_queue_name)['QueueUrl'],
            MessageBody=self.message.body,
            MessageAttributes=self.message.message_attributes
        )


def record_handler(record: SQSRecord) -> Dict[str, str]:
    """ main handler for incoming SQS message
    raises exception if conditional check fails
    :param record: instance of SQSRecord (sqs message)
    :raises PrematureException
    :returns: response object
    """
    msg_body = json_loads(record.body)
    delay = msg_body.get('delay', 0)
    create_timestamp = datetime.strptime(msg_body['createTimestamp'], '%Y-%m-%d %H:%M:%S')
    delayed_timestamp = create_timestamp + timedelta(seconds=delay)
    now = datetime.now()

    logger.info(
        f"Received message with: delay={delay}, create_timestamp={create_timestamp}; "
        f"delayed timestamp is: {delayed_timestamp}, now is: {now}"
    )

    if delay > 0 and delayed_timestamp > now:
        logger.warning(f"Message evaluation result: Message (msg_id={record.message_id}) is premature")
        msg_handler = PrematureMessageHandler(record)
        msg_handler.handle_message()
        status = "PartiallyProcessed"
    else:
        status = "Processed"

    response = {
        "status": status,
        "messageId": record.message_id,
        "messageBody": record.body
    }

    logger.info(f"Response: {response}")

    return response


class SilentBatchProcessor(BatchProcessor):
    """ BatchProcessor subclass that silently reports if all records failed processing """
    def _clean(self):

        if not self._has_messages_to_report():
            return

        if self._entire_batch_failed():
            logger.warning(f"All ({len(self.exceptions)}) records failed processing. Errors: {self.exceptions}")

        messages = self._get_messages_to_report()
        self.batch_response = {"batchItemFailures": messages}


class EventProcessor:
    """ main SQS event processing class """
    def __init__(self, event: Dict[str, Any], context: LambdaContext):
        self.processor = SilentBatchProcessor(event_type=EventType.SQS)
        self.event = event
        self.context = context

    def run(self):
        batch = self.event["Records"]
        logger.info(f"Received following SQS records: {batch}")

        with self.processor(records=batch, handler=record_handler):
            self.processor.process()

        return self.processor.response()


def handler(event: Dict[str, Any], context: LambdaContext) -> Dict[str, Any]:
    """ Lambda function handler
    :param event: incoming SQS event
    :param context: Lambda context
    :return: response object
    """
    return EventProcessor(event, context).run()
