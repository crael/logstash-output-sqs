# encoding: utf-8

require 'aws-sdk'
require 'securerandom'
require 'logstash/errors'
require 'logstash/namespace'
require 'logstash/outputs/base'
require 'logstash/plugin_mixins/aws_config'

Aws.eager_autoload!

# Push events to an Amazon Web Services (AWS) Simple Queue Service (SQS) queue.
#
# SQS is a simple, scalable queue system that is part of the Amazon Web
# Services suite of tools. Although SQS is similar to other queuing systems
# such as Advanced Message Queuing Protocol (AMQP), it uses a custom API and
# requires that you have an AWS account. See http://aws.amazon.com/sqs/ for
# more details on how SQS works, what the pricing schedule looks like and how
# to setup a queue.
#
# The "consumer" identity must have the following permissions on the queue:
#
#   * `sqs:GetQueueUrl`
#   * `sqs:SendMessage`
#   * `sqs:SendMessageBatch`
#
# Typically, you should setup an IAM policy, create a user and apply the IAM
# policy to the user. See http://aws.amazon.com/iam/ for more details on
# setting up AWS identities. A sample policy is as follows:
#
# [source,json]
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Action": [
#         "sqs:GetQueueUrl",
#         "sqs:SendMessage",
#         "sqs:SendMessageBatch"
#       ],
#       "Resource": "arn:aws:sqs:us-east-1:123456789012:my-sqs-queue"
#     }
#   ]
# }
#
# ==== Batch Publishing
# This output publishes messages to SQS in batches in order to optimize event
# throughput and increase performance. This is done using the
# [`SendMessageBatch`](http://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_SendMessageBatch.html)
# API. When publishing messages to SQS in batches, the following service limits
# must be respected (see
# [Limits in Amazon SQS](http://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/limits-messages.html)):
#
#   * The maximum allowed individual message size is 256KiB.
#   * The maximum total payload size (i.e. the sum of the sizes of all
#     individual messages within a batch) is also 256KiB.
#
# This plugin will dynamically adjust the size of the batch published to SQS in
# order to ensure that the total payload size does not exceed 256KiB.
#
# WARNING: This output cannot currently handle messages larger than 256KiB. Any
# single message exceeding this size will be dropped.
#
class LogStash::Outputs::SQS < LogStash::Outputs::Base
  include LogStash::PluginMixins::AwsConfig::V2

  config_name 'sqs'
  default :codec, 'json'

  concurrency :shared

  # The number of events to be sent in each batch. Set this to `1` to disable
  # the batch sending of messages.
  config :batch_events, :validate => :number, :default => 10

  # The maximum number of bytes for any message sent to SQS. Messages exceeding
  # this size will be dropped. See
  # http://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/limits-messages.html.
  config :message_max_size, :validate => :bytes, :default => '256KiB'

  # The name of the target SQS queue. Note that this is just the name of the
  # queue, not the URL or ARN.
  config :queue, :validate => :string, :required => true

  # The message de-duplication id.
  # If a message with a particular MessageDeduplicationId is sent successfully, any messages sent with the same
  # de-duplication id are accepted successfully but aren't delivered during the 5-minute deduplication interval.
  # This parameter applies only to FIFO (first-in-first-out) queues.
  config :message_deduplication_id, :validate => :string, :required => false
  
  # The message group id.
  # The tag that specifies that a message belongs to a specific message group. Messages that belong to the same
  # message group are processed in a FIFO manner
  # This parameter applies only to FIFO (first-in-first-out) queues.
  config :message_group_id, :validate => :string, :required => false, :default => 'default'

  # Account ID of the AWS account which owns the queue. Note IAM permissions
  # need to be configured on both accounts to function.
  config :queue_owner_aws_account_id, :validate => :string, :required => false

  public
  def register
    @sqs = Aws::SQS::Client.new(aws_options_hash)

    if @batch_events > 10
      raise LogStash::ConfigurationError, 'The maximum batch size is 10 events'
    elsif @batch_events < 1
      raise LogStash::ConfigurationError, 'The batch size must be greater than 0'
   end

    begin
      params = { queue_name: @queue }
      params[:queue_owner_aws_account_id] = @queue_owner_aws_account_id if @queue_owner_aws_account_id

      @logger.debug('Connecting to SQS queue', params.merge(region: region))
      @queue_url = @sqs.get_queue_url(params)[:queue_url]
      @logger.info('Connected to SQS queue successfully', params.merge(region: region))
    rescue Aws::SQS::Errors::ServiceError => e
      @logger.error('Failed to connect to SQS', :error => e)
      raise LogStash::ConfigurationError, 'Verify the SQS queue name and your credentials'
    end
  end

  public
  def multi_receive_encoded(encoded_events)
    if @batch_events > 1
      multi_receive_encoded_batch(encoded_events)
    else
      multi_receive_encoded_single(encoded_events)
    end
  end

  private
  def multi_receive_encoded_batch(encoded_events)
    bytes = 0
    entries = []

    # Split the events into multiple batches to ensure that no single batch
    # exceeds `@message_max_size` bytes.
    encoded_events.each_with_index do |encoded_event, index|
      event, encoded = encoded_event

      if encoded.bytesize > @message_max_size
        @logger.warn('Message exceeds maximum length and will be dropped', :message_size => encoded.bytesize)
        next
      end

      if entries.size >= @batch_events or (bytes + encoded.bytesize) > @message_max_size
        send_message_batch(entries)

        bytes = 0
        entries = []
      end

      bytes += encoded.bytesize
      if @queue.include? ".fifo"
        @message_deduplication_id = SecureRandom.uuid if @message_deduplication_id.nil? || @message_deduplication_id.empty?
        entries.push(:id => index.to_s, :message_body => encoded, :message_group_id => @message_group_id, :message_deduplication_id => event.sprintf(@message_deduplication_id))
      else
        entries.push(:id => index.to_s, :message_body => encoded)
      end
    end
    
    send_message_batch(entries) unless entries.empty?
  end

  private
  def multi_receive_encoded_single(encoded_events)
    encoded_events.each do |encoded_event|
      event, encoded = encoded_event

      if encoded.bytesize > @message_max_size
        @logger.warn('Message exceeds maximum length and will be dropped', :message_size => encoded.bytesize)
        next
      end

      @logger.debug("Publishing one message to SQS", :queue_url => @queue_url, :event => event)
      if @queue.include? ".fifo"
        @message_deduplication_id = SecureRandom.uuid if @message_deduplication_id.nil? || @message_deduplication_id.empty?
        @sqs.send_message(:queue_url => @queue_url, :message_body => encoded, :message_group_id => event.sprintf(@message_group_id), :message_deduplication_id => event.sprintf(@message_deduplication_id))
      else
        @sqs.send_message(:queue_url => @queue_url, :message_body => encoded)
      end
    end
  end

  private
  def send_message_batch(entries)
    @logger.debug("Publishing #{entries.size} messages to SQS", :queue_url => @queue_url, :entries => entries)
    @sqs.send_message_batch(:queue_url => @queue_url, :entries => entries)
  end
end
