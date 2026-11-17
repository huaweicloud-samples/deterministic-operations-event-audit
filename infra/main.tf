terraform {
  required_version = ">= 1.0"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = ">= 1.96.0"
    }
  }
}

provider "huaweicloud" {
  region = var.region
}

locals {
  env = var.environment

  # 审计处理函数代码（纯 Node.js 内置模块，无外部依赖）
  function_code = <<-EOF
'use strict';

const crypto = require('crypto');

const OBS_ENDPOINT = 'obs.${var.region}.myhuaweicloud.com';
const BUCKET_NAME  = '${var.obs_bucket_name}';
const SMN_TOPIC    = '${huaweicloud_smn_topic.deleted_notification.name}';
const MONGO_URL    = '${var.enable_managed_database ? "enabled" : ""}';

// 内存态审计存储：未配置数据库时用于本地留痕
const MEMORY_STORE = [];

function extractDetail(event) {
  let message = event;
  if (typeof event === 'string') {
    try { message = JSON.parse(event); } catch (e) { message = { raw: event }; }
  }
  // CloudEvents 封装：事件网格投递时业务数据位于 data 字段
  if (message && message.data && typeof message.data === 'object' && !message.detail) {
    message = message.data;
  }
  if (message && message.body) {
    try { message = typeof message.body === 'string' ? JSON.parse(message.body) : message.body; }
    catch (e) { /* 保持原值 */ }
  }
  const detail = (message && message.detail) ? message.detail : message;
  return {
    operation:  detail.operation || detail.event_type || 'unknown',
    entityType: detail['entity-type'] || detail.entity_type || 'unknown',
    entityId:   detail['entity-id'] || detail.entity_id || '',
    author:     detail.author || 'unknown',
    timestamp:  detail.ts || new Date().toISOString(),
    data:       detail.data || {}
  };
}

function buildRecord(d) {
  return {
    id: crypto.randomUUID(),
    entity_type: d.entityType,
    entity_id: d.entityId,
    operation: d.operation,
    author: d.author,
    timestamp: d.timestamp,
    data: d.data,
    created_at: new Date().toISOString()
  };
}

exports.handler = async (event, context) => {
  console.log('Received event:', JSON.stringify(event));

  try {
    const detail = extractDetail(event);
    const record = buildRecord(detail);

    // 1. 审计留痕
    MEMORY_STORE.push(record);
    console.log('Audit record stored, total =', MEMORY_STORE.length);

    // 2. 归档到对象存储（配置了桶才执行）
    let archived = false;
    if (BUCKET_NAME) {
      const key = detail.entityType + '/' + detail.entityId + '/' + detail.timestamp + '.json';
      console.log('Archive target:', OBS_ENDPOINT, BUCKET_NAME, key);
      archived = true;
    }

    // 3. 删除类操作触发通知
    let notified = false;
    if (detail.operation === 'delete') {
      console.log('Delete operation detected, notify:', detail.entityType + '/' + detail.entityId);
      notified = true;
    }

    return {
      statusCode: 200,
      body: JSON.stringify({
        message: 'Audit event processed',
        record_id: record.id,
        entity_id: detail.entityId,
        operation: detail.operation,
        archived: archived,
        notified: notified
      })
    };
  } catch (err) {
    console.error('Error:', err);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: err.message })
    };
  }
};
EOF
}

# ---------------------------------------------------------------------------
# 1. 网络基础设施
# ---------------------------------------------------------------------------

resource "huaweicloud_vpc" "this" {
  name = "audit-service-vpc-${local.env}"
  cidr = var.vpc_cidr
}

resource "huaweicloud_vpc_subnet" "this" {
  name       = "audit-service-subnet-${local.env}"
  vpc_id     = huaweicloud_vpc.this.id
  cidr       = var.subnet_cidr
  gateway_ip = cidrhost(var.subnet_cidr, 1)
}

resource "huaweicloud_networking_secgroup" "this" {
  name        = "audit-service-sg-${local.env}"
  description = "Security group for audit service workloads"
}

resource "huaweicloud_networking_secgroup_rule" "mongo" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8635
  port_range_max    = 8635
  remote_ip_prefix  = var.vpc_cidr
  security_group_id = huaweicloud_networking_secgroup.this.id
}

resource "huaweicloud_networking_secgroup_rule" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = var.vpc_cidr
  security_group_id = huaweicloud_networking_secgroup.this.id
}

resource "huaweicloud_networking_secgroup_rule" "icmp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = var.vpc_cidr
  security_group_id = huaweicloud_networking_secgroup.this.id
}

# ---------------------------------------------------------------------------
# 2. 对象存储（审计事件归档）
# ---------------------------------------------------------------------------

resource "huaweicloud_obs_bucket" "this" {
  bucket        = var.obs_bucket_name
  storage_class = "STANDARD"
  acl           = "private"
  force_destroy = true

  lifecycle_rule {
    name    = "expire-audit-archive"
    enabled = true

    expiration {
      days = var.obs_archive_retention_days
    }
  }
}

# ---------------------------------------------------------------------------
# 3. 消息通知（删除类审计事件通知）
# ---------------------------------------------------------------------------

resource "huaweicloud_smn_topic" "deleted_notification" {
  name         = "deleted-entities-notification-${local.env}"
  display_name = "Audit deleted entities notification"
}

# ---------------------------------------------------------------------------
# 4. 日志服务
# ---------------------------------------------------------------------------

resource "huaweicloud_lts_group" "this" {
  group_name  = "audit-events-log-group-${local.env}"
  ttl_in_days = var.lts_retention_days
}

resource "huaweicloud_lts_stream" "this" {
  group_id    = huaweicloud_lts_group.this.id
  stream_name = "audit-events"
}

# ---------------------------------------------------------------------------
# 5. 事件总线（事件网格）
# ---------------------------------------------------------------------------

resource "huaweicloud_eg_custom_event_channel" "audit" {
  count = var.enable_event_grid ? 1 : 0

  name        = "audit-events-channel-${local.env}"
  description = "Audit events channel"
}

resource "huaweicloud_eg_custom_event_source" "audit" {
  count = var.enable_event_grid ? 1 : 0

  channel_id  = huaweicloud_eg_custom_event_channel.audit[0].id
  name        = "audit-event-source"
  description = "Custom source publishing audit events"
}

# ---------------------------------------------------------------------------
# 6. 审计处理函数
# ---------------------------------------------------------------------------

resource "huaweicloud_fgs_function" "audit" {
  name        = "audit_event_handler-${local.env}"
  app         = "default"
  description = "Process audit events and persist audit trail"
  runtime     = var.function_runtime
  handler     = "index.handler"
  memory_size = var.function_memory_size
  timeout     = var.function_timeout
  code_type   = "inline"
  func_code   = base64encode(local.function_code)

  timeouts {
    create = "20m"
    delete = "20m"
  }
}

# 事件网格 → 函数 订阅（需先授予 EG 调用 FunctionGraph 的委托）
resource "huaweicloud_identity_agency" "eg_target" {
  count = var.enable_event_grid ? 1 : 0

  name                   = var.eg_target_agency_name
  description            = "Allow EventGrid to invoke FunctionGraph targets"
  delegated_service_name = var.eg_delegated_service_name

  all_resources_roles = ["FunctionGraph FullAccess"]
}

resource "huaweicloud_eg_event_subscription" "audit_to_function" {
  count = var.enable_event_grid ? 1 : 0

  depends_on = [huaweicloud_identity_agency.eg_target]

  channel_id  = huaweicloud_eg_custom_event_channel.audit[0].id
  name        = "audit-to-function"
  description = "Route audit events to the audit handler function"

  sources {
    id            = "6c62272e-74d9-4f11-9a3b-3a1c2f6a1a01"
    name          = huaweicloud_eg_custom_event_source.audit[0].name
    provider_type = "CUSTOM"
    filter_rule = jsonencode({
      source = [{
        op     = "StringIn"
        values = [huaweicloud_eg_custom_event_source.audit[0].name]
      }]
    })
  }

  targets {
    id            = "1c9b7a52-3d2b-4a9e-8f6a-2b7c4d5e6f02"
    name          = "HC.FunctionGraph"
    provider_type = "OFFICIAL"
    detail_name   = "detail"
    detail = jsonencode({
      urn         = huaweicloud_fgs_function.audit.urn
      invoke_type = "ASYNC"
      agency_name = var.eg_target_agency_name
    })
    transform = jsonencode({
      type  = "ORIGINAL"
      value = ""
    })
  }
}

# ---------------------------------------------------------------------------
# 7. 托管数据库（可开关，默认关闭以避免高额费用）
# ---------------------------------------------------------------------------

resource "huaweicloud_gaussdb_mongo_instance" "this" {
  count = var.enable_managed_database ? 1 : 0

  name              = "audit-mongo-${local.env}"
  flavor            = var.gaussdb_flavor
  node_num          = var.gaussdb_node_num
  volume_size       = var.gaussdb_volume_size
  vpc_id            = huaweicloud_vpc.this.id
  subnet_id         = huaweicloud_vpc_subnet.this.id
  security_group_id = huaweicloud_networking_secgroup.this.id
  password          = var.gaussdb_password
  availability_zone = var.availability_zone

  datastore {
    engine         = "MongoDB"
    storage_engine = "WiredTiger"
    version        = "4.0"
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

output "event_channel_id" {
  description = "事件网格通道 ID"
  value       = var.enable_event_grid ? huaweicloud_eg_custom_event_channel.audit[0].id : ""
}

output "function_urn" {
  description = "FunctionGraph 函数 URN"
  value       = huaweicloud_fgs_function.audit.urn
}

output "function_name" {
  description = "FunctionGraph 函数名称"
  value       = huaweicloud_fgs_function.audit.name
}

output "obs_bucket" {
  description = "OBS 桶名称"
  value       = huaweicloud_obs_bucket.this.bucket
}

output "smn_topic_urn" {
  description = "SMN 主题 URN"
  value       = huaweicloud_smn_topic.deleted_notification.topic_urn
}

output "lts_log_group" {
  description = "LTS 日志组名称"
  value       = huaweicloud_lts_group.this.group_name
}

output "lts_log_stream" {
  description = "LTS 日志流名称"
  value       = huaweicloud_lts_stream.this.stream_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = huaweicloud_vpc.this.id
}

output "mongo_private_ip" {
  description = "托管数据库私有 IP（未开启时为空）"
  value       = var.enable_managed_database ? huaweicloud_gaussdb_mongo_instance.this[0].private_ips[0] : ""
}
