variable "region" {
  description = "华为云区域"
  type        = string
  default     = "cn-north-4"
}

variable "availability_zone" {
  description = "可用区（托管数据库使用）"
  type        = string
  default     = "cn-north-4a"
}

variable "environment" {
  description = "环境名称，用于资源命名后缀"
  type        = string
  default     = "demo"
}

variable "vpc_cidr" {
  description = "VPC 网段"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "子网网段"
  type        = string
  default     = "10.0.1.0/24"
}

variable "obs_bucket_name" {
  description = "OBS 桶名称，需全局唯一"
  type        = string
  default     = "audit-service-archive-demo-2026"
}

variable "obs_archive_retention_days" {
  description = "审计归档保留天数"
  type        = number
  default     = 30
}

variable "lts_retention_days" {
  description = "日志组保留天数"
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# 计算与事件
# ---------------------------------------------------------------------------

variable "function_runtime" {
  description = "函数运行时"
  type        = string
  default     = "Node.js18.15"
}

variable "function_memory_size" {
  description = "函数内存（MB）"
  type        = number
  default     = 256
}

variable "function_timeout" {
  description = "函数超时时间（秒）"
  type        = number
  default     = 60
}

variable "enable_event_grid" {
  description = "是否创建事件网格通道与订阅（事件总线，按事件量结算）"
  type        = bool
  default     = true
}

variable "eg_target_agency_name" {
  description = "事件网格调用函数时使用的委托名称"
  type        = string
  default     = "EG_TARGET_AGENCY"
}

variable "eg_delegated_service_name" {
  description = "委托给云服务的服务名（事件网格）"
  type        = string
  default     = "op_svc_eg"
}

# ---------------------------------------------------------------------------
# 托管数据库（付费资源，默认关闭）
# ---------------------------------------------------------------------------

variable "enable_managed_database" {
  description = "是否创建托管数据库实例。该资源按月订阅，默认关闭"
  type        = bool
  default     = false
}

variable "gaussdb_user" {
  description = "托管数据库用户名"
  type        = string
  default     = "root"
}

variable "gaussdb_password" {
  description = "托管数据库密码，需满足复杂度要求"
  type        = string
  sensitive   = true
  default     = "AuditSvc2026#"
}

variable "gaussdb_flavor" {
  description = "托管数据库规格"
  type        = string
  default     = "geminidb.mongodb.medium.4.replica"
}

variable "gaussdb_node_num" {
  description = "托管数据库节点数"
  type        = number
  default     = 3
}

variable "gaussdb_volume_size" {
  description = "托管数据库磁盘容量（GB）"
  type        = number
  default     = 100
}
