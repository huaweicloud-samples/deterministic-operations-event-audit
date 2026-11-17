# EventBridge Audit Service


> [English](README.md)
基于华为云**事件网格（EG）+ FunctionGraph** 构建的事件驱动型审计服务，用于记录和追踪系统中的实体变更事件。

## 这个服务能做什么？

当业务系统发生数据变更时（如创建、更新、删除操作），本服务可以：

| 功能 | 说明 |
|------|------|
| **事件采集** | 通过事件网格自定义事件通道接收业务系统的变更事件（实体类型、操作类型、时间戳、操作者等） |
| **事件路由** | 通过事件订阅规则按事件来源/类型自动过滤并路由到处理函数 |
| **数据持久化** | 将变更数据归档到对象存储，便于后续查询与合规追溯 |
| **删除通知** | 当实体被删除时，自动触发通知消息 |
| **日志记录** | 全链路日志记录，用于调试与审计取证 |

### 典型使用场景

**场景 1：数据库变更审计**
- 业务系统发生数据变更时，向事件通道投递审计事件
- 审计服务自动将变更数据归档到 OBS
- 管理员可以查询历史变更记录

**场景 2：文件操作审计**
- 文件上传、下载、删除等操作产生事件
- 审计服务记录操作人、时间、操作类型
- 可用于安全合规和故障排查

**场景 3：删除保护**
- 当重要数据被删除时，自动发送通知
- 管理员可以及时发现并处理异常删除

## 架构图

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  业务系统     │────▶│  事件网格 EG      │────▶│  FunctionGraph   │
│  (事件源)    │     │  事件通道+订阅    │     │  (事件处理)      │
└──────────────┘     └──────────────────┘     └────────┬─────────┘
                                                        │
                    ┌────────────────────────────────────┼────────────────────────────┐
                    │                                    │                            │
                    ▼                                    ▼                            ▼
           ┌──────────────────┐           ┌──────────────────┐           ┌──────────────────┐
           │       OBS        │           │  GaussDB(for Mongo)│         │      SMN        │
           │  (审计归档)      │           │   (事件明细存储)  │           │    (删除通知)    │
           └──────────────────┘           └──────────────────┘           └──────────────────┘
```

事件流转过程：

1. 业务系统按 CloudEvents 规范向事件网格自定义事件通道投递事件
2. 事件订阅按 `source` 过滤规则匹配事件
3. 命中规则的事件被异步投递到 FunctionGraph 函数（通过委托授权）
4. 函数解析事件，完成审计留痕、归档与通知

## 事件格式

投递到事件通道的 CloudEvents 消息：

```json
{
  "id": "evt-audit-0001",
  "source": "audit-event-source",
  "specversion": "1.0",
  "type": "audit.event",
  "datacontenttype": "application/json",
  "time": "2026-09-14T03:25:00Z",
  "subject": "document/doc-1001",
  "data": {
    "operation": "delete",
    "entity-type": "document",
    "entity-id": "doc-1001",
    "author": "dave",
    "ts": "2026-09-14T03:25:00Z",
    "data": {
      "title": "Q3 Report"
    }
  }
}
```

函数同时兼容直接调用传参形式：

```json
{
  "detail": {
    "operation": "insert | update | delete",
    "entity-type": "<entity-type>",
    "entity-id": "<entity-id>",
    "author": "<user-who-triggered-change>",
    "ts": "<timestamp>",
    "data": {}
  }
}
```

## 处理结果

函数返回示例（删除事件）：

```json
{
  "statusCode": 200,
  "body": "{\"message\":\"Audit event processed\",\"record_id\":\"57db7e48-2783-442e-bd2f-e98c37b212ea\",\"entity_id\":\"doc-1001\",\"operation\":\"delete\",\"archived\":true,\"notified\":true}"
}
```

`notified` 在删除类操作时为 `true`，表示已触发通知流程。

## 技术栈

| 组件 | 技术 |
|------|------|
| 事件总线 | 华为云事件网格（EG）自定义事件通道 + 事件订阅 |
| 计算服务 | 华为云 FunctionGraph（Node.js 18.15） |
| 对象存储 | 华为云 OBS |
| 文档数据库 | 华为云 GaussDB(for Mongo)（可选，默认关闭） |
| 消息通知 | 华为云 SMN |
| 日志服务 | 华为云 LTS |
| 身份授权 | 华为云 IAM 委托 |
| 基础设施即代码 | Terraform |

## 快速开始

### 前置条件

- 华为云账号
- 已开通：事件网格、FunctionGraph、OBS、SMN、LTS
- Terraform 1.0+

### 部署步骤

1. **克隆代码**

```bash
git clone https://github.com/huaweicloud-samples/deterministic-operations-event-audit.git
cd deterministic-operations-event-audit
```

2. **配置凭据**

```bash
export HW_ACCESS_KEY="your-access-key"
export HW_SECRET_KEY="your-secret-key"
export HW_REGION_NAME="cn-north-4"
```

3. **部署**

```bash
cd infra
terraform init
terraform plan
terraform apply
```

部署完成后会输出事件通道 ID、函数 URN、OBS 桶名、SMN 主题 URN 等关键信息。

4. **验证**

向事件通道推送一条测试事件（使用华为云 EG SDK）：

```python
from huaweicloudsdkeg.v1 import EgClient
from huaweicloudsdkeg.v1.region.eg_region import EgRegion
from huaweicloudsdkeg.v1.model import PutEventsRequest
from huaweicloudsdkcore.auth.credentials import BasicCredentials

client = EgClient.new_builder() \
    .with_credentials(BasicCredentials(ak, sk, project_id)) \
    .with_region(EgRegion.value_of("cn-north-4")) \
    .build()

client.put_events(PutEventsRequest(
    channel_id="<terraform output event_channel_id>",
    body={"events": [{
        "id": "evt-0001",
        "source": "audit-event-source",
        "specversion": "1.0",
        "type": "audit.event",
        "datacontenttype": "application/json",
        "time": "2026-09-14T03:25:00Z",
        "data": {
            "operation": "delete",
            "entity-type": "document",
            "entity-id": "doc-1001",
            "author": "dave",
            "ts": "2026-09-14T03:25:00Z"
        }
    }]}
))
```

## 配置项说明

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `region` | 华为云区域 | `cn-north-4` |
| `environment` | 环境后缀，用于资源命名 | `demo` |
| `obs_bucket_name` | OBS 桶名称（需全局唯一） | `audit-service-archive-demo-2026` |
| `function_runtime` | 函数运行时 | `Node.js18.15` |
| `function_memory_size` | 函数内存（MB） | `256` |
| `enable_event_grid` | 是否创建事件通道与订阅 | `true` |
| `enable_managed_database` | 是否创建文档数据库实例（按月订阅） | `false` |

## 项目结构

```
deterministic-operations-event-audit/
├── docs/
│   ├── architecture.md
│   └── deployment-guide.md
├── infra/
│   ├── main.tf
│   └── variables.tf
├── src/
│   └── handler.js
├── LICENSE
├── README.md
└── README.cn.md
```

## 清理资源

```bash
cd infra
terraform destroy
```

## 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件
