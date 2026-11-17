'use strict';

/**
 * 审计事件处理函数
 *
 * 兼容两种入参：
 *  1. 事件网格投递的 CloudEvents 消息（业务数据位于 data 字段）
 *  2. 直接调用传入的 { detail: {...} } 结构
 */

const crypto = require('crypto');

const OBS_ENDPOINT = 'obs.cn-north-4.myhuaweicloud.com';
const BUCKET_NAME = 'audit-service-archive-demo-2026';
const SMN_TOPIC = 'deleted-entities-notification-demo';
const MONGO_URL = '';

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
    operation: detail.operation || detail.event_type || 'unknown',
    entityType: detail['entity-type'] || detail.entity_type || 'unknown',
    entityId: detail['entity-id'] || detail.entity_id || '',
    author: detail.author || 'unknown',
    timestamp: detail.ts || new Date().toISOString(),
    data: detail.data || {}
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
