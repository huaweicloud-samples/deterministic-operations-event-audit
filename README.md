# EventBridge Audit Service


> [中文](README.cn.md)
An event-driven audit service built on Huawei Cloud **EventGrid (EG) + FunctionGraph**, used to record and trace entity change events across business systems.

## What Does This Service Do?

When a business system performs data changes (create / update / delete), this service:

| Capability | Description |
|------------|-------------|
| **Event ingestion** | Receives change events (entity type, operation, timestamp, author, etc.) through an EventGrid custom event channel |
| **Event routing** | Filters and routes events to the handler function via subscription rules based on source / type |
| **Persistence** | Archives change data to object storage for later queries and compliance tracing |
| **Delete notification** | Automatically triggers a notification when an entity is deleted |
| **Logging** | Full-pipeline logging for debugging and audit forensics |

### Typical Use Cases

**Scenario 1: Database change auditing**
- Business systems publish audit events to the event channel on data changes
- The service archives change data to OBS automatically
- Administrators can query historical change records

**Scenario 2: File operation auditing**
- Upload / download / delete operations generate events
- The service records operator, time, and operation type
- Useful for security compliance and troubleshooting

**Scenario 3: Delete protection**
- When critical data is deleted, a notification is sent automatically
- Administrators can detect and handle abnormal deletions promptly

## Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Business    │────▶│  EventGrid (EG)  │────▶│  FunctionGraph   │
│  system      │     │  channel + sub   │     │  (event handler) │
└──────────────┘     └──────────────────┘     └────────┬─────────┘
                                                       │
                    ┌───────────────────────────────────┼────────────────────────────┐
                    │                                   │                            │
                    ▼                                   ▼                            ▼
           ┌──────────────────┐           ┌──────────────────┐           ┌──────────────────┐
           │       OBS        │           │ GaussDB(for Mongo)│          │      SMN         │
           │  (archive)       │           │  (event store)   │           │  (notification)  │
           └──────────────────┘           └──────────────────┘           └──────────────────┘
```

Event flow:

1. The business system publishes CloudEvents-formatted events to the EG custom event channel
2. The event subscription matches events by the `source` filter rule
3. Matched events are delivered asynchronously to the FunctionGraph function (via IAM agency authorization)
4. The function parses the event and performs audit trail, archiving, and notification

## Event Format

A CloudEvent delivered to the channel:

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

The function also accepts direct invocation payloads:

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

## Response

Sample function response (delete event):

```json
{
  "statusCode": 200,
  "body": "{\"message\":\"Audit event processed\",\"record_id\":\"57db7e48-2783-442e-bd2f-e98c37b212ea\",\"entity_id\":\"doc-1001\",\"operation\":\"delete\",\"archived\":true,\"notified\":true}"
}
```

`notified` is `true` for delete operations, indicating the notification flow was triggered.

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Event bus | Huawei Cloud EventGrid (EG) custom channel + event subscription |
| Compute | Huawei Cloud FunctionGraph (Node.js 18.15) |
| Object storage | Huawei Cloud OBS |
| Document database | Huawei Cloud GaussDB(for Mongo) (optional, disabled by default) |
| Notification | Huawei Cloud SMN |
| Logging | Huawei Cloud LTS |
| Authorization | Huawei Cloud IAM agency |
| Infrastructure as Code | Terraform |

## Getting Started

### Prerequisites

- A Huawei Cloud account
- Enabled services: EventGrid, FunctionGraph, OBS, SMN, LTS
- Terraform 1.0+

### Deployment

1. **Clone the repository**

```bash
git clone https://github.com/huaweicloud-samples/deterministic-operations-event-audit.git
cd deterministic-operations-event-audit
```

2. **Configure credentials**

```bash
export HW_ACCESS_KEY="your-access-key"
export HW_SECRET_KEY="your-secret-key"
export HW_REGION_NAME="cn-north-4"
```

3. **Deploy**

```bash
cd infra
terraform init
terraform plan
terraform apply
```

Terraform outputs the event channel ID, function URN, OBS bucket name, SMN topic URN, and other key values.

4. **Verify**

Publish a test event to the channel (using the EG SDK):

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

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `region` | Huawei Cloud region | `cn-north-4` |
| `environment` | Environment suffix for resource naming | `demo` |
| `obs_bucket_name` | OBS bucket name (must be globally unique) | `audit-service-archive-demo-2026` |
| `function_runtime` | Function runtime | `Node.js18.15` |
| `function_memory_size` | Function memory (MB) | `256` |
| `enable_event_grid` | Create the event channel and subscription | `true` |
| `enable_managed_database` | Create the document database instance (monthly subscription) | `false` |

## Project Structure

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

## Cleanup

```bash
cd infra
terraform destroy
```

## License

MIT License - see the [LICENSE](LICENSE) file for details.
