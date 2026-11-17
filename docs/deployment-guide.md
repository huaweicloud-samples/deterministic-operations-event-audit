# 部署指南

## 1. 前置准备

### 1.1 环境要求

| 项目 | 要求 |
|------|------|
| 华为云账号 | 已完成实名认证 |
| Terraform | 1.0 及以上 |
| 网络 | 可访问华为云 API 端点 |
| 区域 | 默认 `cn-north-4`（华北-北京四） |

### 1.2 开通服务

以下服务需在控制台开通：

- 事件网格（EG）
- 函数工作流（FunctionGraph）
- 对象存储（OBS）
- 消息通知服务（SMN）
- 云日志服务（LTS）

### 1.3 获取访问密钥

在华为云控制台「我的凭证 → 访问密钥」中创建 AK/SK。

## 2. 配置凭据

Terraform 使用以下环境变量读取华为云凭据：

```bash
# Linux / macOS
export HW_ACCESS_KEY="your-access-key"
export HW_SECRET_KEY="your-secret-key"
export HW_REGION_NAME="cn-north-4"
```

```powershell
# Windows PowerShell
$env:HW_ACCESS_KEY="your-access-key"
$env:HW_SECRET_KEY="your-secret-key"
$env:HW_REGION_NAME="cn-north-4"
```

> 注意：环境变量名为 `HW_ACCESS_KEY` / `HW_SECRET_KEY`，不是 `HW_ACCESS_KEY_ID`。

## 3. 部署步骤

### 3.1 初始化

```bash
cd infra
terraform init
```

### 3.2 预演

```bash
terraform plan
```

预期输出为待创建的资源清单（默认约 15 个资源）。

### 3.3 应用

```bash
terraform apply
```

输入 `yes` 确认。部署通常在 1 分钟内完成。

### 3.4 查看输出

```bash
terraform output
```

关键输出说明：

| 输出 | 说明 |
|------|------|
| `event_channel_id` | 事件通道 ID，推送事件时使用 |
| `function_urn` | 函数 URN |
| `obs_bucket` | OBS 桶名称 |
| `smn_topic_urn` | SMN 主题 URN |
| `lts_log_group` | LTS 日志组名称 |
| `vpc_id` | VPC ID |

## 4. 部署后验证

### 4.1 检查资源

```bash
# 查看函数配置
hwcli functiongraph show-function-config --function_urn <function_urn>

# 查看函数触发器（应看到 EVENTGRID 类型且状态为 ACTIVE）
hwcli functiongraph list-function-triggers --function_urn <function_urn>
```

### 4.2 推送测试事件

使用华为云事件网格 SDK 推送 CloudEvent：

```python
import os
from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkeg.v1 import EgClient
from huaweicloudsdkeg.v1.region.eg_region import EgRegion
from huaweicloudsdkeg.v1.model import PutEventsRequest

client = EgClient.new_builder() \
    .with_credentials(BasicCredentials(
        os.environ["HW_ACCESS_KEY"],
        os.environ["HW_SECRET_KEY"],
        "<your-project-id>")) \
    .with_region(EgRegion.value_of("cn-north-4")) \
    .build()

resp = client.put_events(PutEventsRequest(
    channel_id="<event_channel_id>",
    body={"events": [{
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
            "ts": "2026-09-14T03:25:00Z"
        }
    }]}
))

print(resp.to_str())
```

成功时返回 `failed_count: 0`。

### 4.3 直接调用函数验证逻辑

```python
from huaweicloudsdkfunctiongraph.v2 import FunctionGraphClient
from huaweicloudsdkfunctiongraph.v2.region.functiongraph_region import FunctionGraphRegion
from huaweicloudsdkfunctiongraph.v2.model import InvokeFunctionRequest

client = FunctionGraphClient.new_builder() \
    .with_credentials(BasicCredentials(ak, sk, project_id)) \
    .with_region(FunctionGraphRegion.value_of("cn-north-4")) \
    .build()

resp = client.invoke_function(InvokeFunctionRequest(
    function_urn="<function_urn>",
    x_cff_log_type="tail",
    body={"detail": {
        "operation": "delete",
        "entity-type": "document",
        "entity-id": "doc-1001",
        "author": "carol",
        "ts": "2026-09-14T03:10:00Z",
        "data": {}
    }}))
print(resp.raw_content)
```

预期返回：

```json
{"statusCode":200,"body":"{\"message\":\"Audit event processed\",\"record_id\":\"...\",\"operation\":\"delete\",\"archived\":true,\"notified\":true}"}
```

### 4.4 查看事件轨迹

在华为云控制台「事件网格 → 事件轨迹」中可按事件 ID、来源或订阅名称查询事件的投递记录。

## 5. 可选配置

### 5.1 开启托管数据库

默认不创建文档数据库实例（按月订阅）。如需开启：

```bash
terraform apply -var="enable_managed_database=true"
```

开启后需同步调整 `gaussdb_flavor`、`gaussdb_node_num`、`gaussdb_password` 等参数。

### 5.2 关闭事件网格

仅需函数与存储资源时：

```bash
terraform apply -var="enable_event_grid=false"
```

### 5.3 多环境并存

通过 `environment` 变量区分环境，所有资源名会自动带后缀：

```bash
terraform apply -var="environment=staging"
```

### 5.4 自定义 OBS 桶名

OBS 桶名需全局唯一，若默认名称冲突请替换：

```bash
terraform apply -var="obs_bucket_name=my-audit-archive-2026"
```

## 6. 常见问题

| 问题 | 原因 | 处理方式 |
|------|------|----------|
| `invalid parameters, agency name is null` | 事件订阅未配置委托 | 确认 `eg_target_agency_name` 已配置且委托创建成功 |
| `BucketAlreadyExists` | OBS 桶名被占用 | 更换 `obs_bucket_name` |
| 函数调用返回 401 | 凭据错误或签名不正确 | 检查 AK/SK，或改用官方 SDK |
| 事件推送后函数无反应 | 过滤规则不匹配 | 检查 CloudEvent 的 `source` 是否等于事件源名称 |
| 创建代理报 `duration is invalid` | 云服务委托不允许指定时长 | 省略 `duration` 参数 |

## 7. 资源清理

```bash
cd infra
terraform destroy
```

确认输出 `Destroy complete!` 后，所有资源已释放，不再产生费用。

> OBS 桶配置了 `force_destroy = true`，销毁时会一并清空桶内对象。
