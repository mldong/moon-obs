# moon-obs · 官方 OBS SDK 对标台账

> 协议基线：[OBS API 概览](https://support.huaweicloud.com/api-obs/obs_04_0005.html)
> 参考实现：`huaweicloud/huaweicloud-sdk-python-obs@v3.26.6`（2026-07-10）；交叉核对 Go `v3.26.6`（2026-07-21）
> 本仓版本：`mldong/moon-obs@0.4.0`
> 当前公开面：62 个 `Client::` 方法（0.4.0）
> 状态：现有行先记 `已实现`，真桶证据待按基线逐行复核

## 1. 当前公开面

| ID | 能力族 | 官方操作 | 我们的方法 | 档 | 状态 | 证据/备注 |
|---|---|---|---|---|---|---|
| OBS-OBJ-001 | 对象 CRUD | PUT / GET / HEAD / DELETE / PUT Copy | `put_object` `get_object` `stat_object` `delete_object` `copy_object` | P0 | 真桶已验证 | `obs/live_test.mbt`（2026-10-22 真桶绿） |
| OBS-OBJ-002 | 列举 | GET Bucket（V1，marker/NextMarker） | `list_objects` | P0 | 真桶已验证 | `obs/live_test.mbt`（2026-10-22 真桶绿）；S3 兼容面 v2 另记 |
| OBS-OBJ-003 | 批量删除 | DeleteObjects | `delete_objects` | P0 | 真桶已验证 | `obs/delete_ops_wbtest.mbt`、`obs/live_extra_test.mbt`（2026-10-22 真桶绿） |
| OBS-OBJ-005 | 对象标签 | Put/Get/DeleteObjectTagging | `put_object_tagging` `get_object_tagging` `delete_object_tagging` | P0 | 真桶已验证 | `obs/tagging_ops_wbtest.mbt`、`obs/live_extra_test.mbt`（2026-10-22 真桶绿） |
| OBS-OBJ-007 | 条件请求 | If-Match/If-None-Match + If-Modified-Since/If-Unmodified-Since + 复制源条件 | `put_object` `get_object` `stat_object` `delete_object` `copy_object` `upload_part_copy` 的可选参数 | P0 | 真桶已验证 | `obs/object_options_wbtest.mbt`、`obs/live_extra_test.mbt`（2026-10-22 真桶绿） |
| OBS-MPU-001 | 分片 | Initiate / UploadPart / ListParts / Complete / Abort | `create_multipart_upload` `upload_part` `list_parts` `complete_multipart_upload` `abort_multipart_upload` | P0 | 真桶已验证 | `obs/live_test.mbt`（2026-10-22 真桶绿） |
| OBS-MPU-002 | 分片复制 | CopyPart / UploadPartCopy | `upload_part_copy` | P0 | 真桶已验证 | `obs/multipart_extra_wbtest.mbt`、`obs/live_extra_test.mbt`（2026-10-22 真桶绿） |
| OBS-MPU-003 | 未完成分片 | ListMultipartUploads | `list_multipart_uploads` | P0 | 真桶已验证 | `obs/multipart_extra_wbtest.mbt`、`obs/live_extra_test.mbt`（2026-10-22 真桶绿） |
| OBS-PRE-001 | 预签名 | V4 查询串（GET/PUT） | `presigned_get_url` `presigned_put_url` | P0 | 真桶已验证 | `obs/live_test.mbt`（2026-10-22 真桶绿） |
| OBS-ACL-001 | 对象 ACL | GetObjectAcl / PutObjectAcl | `get_object_acl` `put_object_acl` | P0 | 真桶已验证 | `obs/live_test.mbt`（2026-10-22 真桶绿）；回体 grant 形状按实测 |
| OBS-BKT-001 | 服务级列举 | ListBuckets | `list_buckets` | P1 | 真桶已验证 | `obs/live_test.mbt`（2026-10-22 真桶绿） |
| OBS-BKT-002 | 桶基础 | PutBucket / DeleteBucket / HeadBucket | `create_bucket` `delete_bucket` `bucket_exists` | P1 | 已实现 | `obs/bucket_admin_wbtest.mbt`；`bucket_exists` 2026-10-22 真桶绿；建/删桶不跑真桶 |
| OBS-BKT-003 | 桶 ACL | GetBucketAcl / PutBucketAcl | `get_bucket_acl` `put_bucket_acl` | P1 | 已实现 | `obs/acl_ops.mbt` 复用对象 ACL 解析；GET 2026-10-22 真桶绿，PUT 未跑 |
| OBS-BKT-005 | 版本控制 | GetBucketVersioning / PutBucketVersioning | `get_bucket_versioning` `put_bucket_versioning` | P1 | 已实现 | `obs/versioning_ops_wbtest.mbt`；GET 2026-10-22 真桶绿，PUT 未跑 |
| OBS-OBJ-013 | 归档解冻 | RestoreObject | `restore_object` | P1 | 已实现 | `obs/restore_ops_wbtest.mbt`；真桶待补（需归档对象） |
| OBS-BKT-004 | CORS | Get/Put/DeleteBucketCORS | `get_bucket_cors` `put_bucket_cors` `delete_bucket_cors` | P1 | 已实现 | `obs/cors_ops_wbtest.mbt`；GET 2026-10-22 真桶绿（无配置回空），PUT/DELETE 未跑 |

## 2. 缺口台账

### P0 · 数据面核心

| ID | 官方操作 | 我们的方法 | 状态 | 备注 |
|---|---|---|---|---|
| OBS-OBJ-006 | x-amz-storage-class（存储类） | 写入 `put_object`/`copy_object`/`create_multipart_upload`；回读 `stat_object`/`list_objects` | 真桶已验证 | 2026-10-22 真桶绿；标准档 HEAD 省略该头，List 可读；`ObjectStat`/`ObjectInfo` 已加字段，需抬版本 |
| OBS-OBJ-008 | Content-MD5 / ETag 校验 | `put_object` / `upload_part` 已收 `content_md5~` 或 `compute_md5~` | 实现中 | 自动 MD5 2026-10-22 真桶绿；ETag 只读回 |

### P1 · 控制面与厂商数据面扩展

| ID | 能力/官方操作 | 我们的方法 | 档 | 状态 | 证据/备注 |
|---|---|---|---|---|---|
| OBS-OBJ-009 | 追加写（AppendObject） | `append_object` | P1 | 真桶已验证 | `obs/append_ops_wbtest.mbt`、`obs/live_extra_test.mbt`（2026-10-22） |
| OBS-OBJ-010 | 截断（TruncateObject） | `truncate_object` | P1 | 部分真桶 | POSIX 桶专属：普通桶实测 405，未验证 |
| OBS-OBJ-011 | 重命名（RenameObject） | `rename_object` | P1 | 部分真桶 | POSIX 桶专属：普通桶实测 405，未验证 |
| OBS-OBJ-012 | 修改（UploadModifyObject） | `modify_object` | P1 | 部分真桶 | POSIX 桶专属：普通桶实测 405，未验证 |
| OBS-OBJ-014 | 通知/回调（Notification/Callback） | — | P1 | 未开始 | 事件通知与回调 |
| OBS-BKT-006 | 桶标签（Get/Put/DeleteBucketTagging） | `get_bucket_tagging` `put_bucket_tagging` `delete_bucket_tagging` | P1 | 已实现 | GET 2026-10-22 真桶绿；PUT/DELETE 未跑 |
| OBS-BKT-007 | 桶日志（Get/PutBucketLogging） | `get_bucket_logging` `put_bucket_logging` | P1 | 已实现 | GET 2026-10-22 真桶绿；PUT 未跑 |
| OBS-BKT-008 | 防盗链（Referer） | — | P1 | 不纳入 | 官方 Python 基线 `obs/client.py` 无 referer 方法 |
| OBS-BKT-013 | 网站托管（Get/Put/DeleteBucketWebsite） | `get_bucket_website` `put_bucket_website` `delete_bucket_website` | P1 | 已实现 | GET 2026-10-22 真桶绿；PUT/DELETE 未跑 |
| OBS-BKT-009 | 生命周期（Get/Put/DeleteBucketLifecycle） | `get_bucket_lifecycle` `put_bucket_lifecycle` `delete_bucket_lifecycle` | P1 | 部分真桶 | 读 2026-10-22 真桶绿（1 条规则）；写只落离线件 |
| OBS-BKT-016 | 复制（Get/Put/DeleteBucketReplication） | `get_bucket_replication` `put_bucket_replication` `delete_bucket_replication` | P1 | 部分真桶 | 读 2026-10-22 真桶绿（未配置回 None）；写只落离线件 |
| OBS-BKT-014 | 服务端加密（Get/Put/DeleteBucketEncryption） | `get_bucket_encryption` `put_bucket_encryption` `delete_bucket_encryption` | P1 | 已实现 | GET 2026-10-22 真桶绿；PUT/DELETE 未跑 |
| OBS-BKT-010 | 清单（Inventory 四件） | `put_bucket_inventory` `get_bucket_inventory` `delete_bucket_inventory` `list_bucket_inventories` | P1 | 部分真桶 | 该桶 ListBucketInventory 实测 405（能力/区域限制），按读数记录；写只落离线件 |
| OBS-BKT-018 | 对象锁（Object Lock） | — | P1 | 未开始 | 对象锁 |
| OBS-BKT-017 | 桶策略（Get/Put/DeleteBucketPolicy） | `get_bucket_policy` `put_bucket_policy` `delete_bucket_policy` | P1 | 部分真桶 | 读 2026-10-22 真桶绿（未配置回 None）；写只落离线件 |
| OBS-BKT-011 | 配额/存储信息/自定义域（Quota/StorageInfo/CustomDomain） | — | P1 | 未开始 | 配额、存储信息、自定义域 |
| OBS-BKT-012 | 冷直读/镜像回源/DIS/解压（DirectColdAccess/Mirror/DIS/Decompress） | — | P1 | 未开始 | OBS 特有桶能力 |

### P2 · 便利/安全层

| ID | 能力 | 状态 | 备注 |
|---|---|---|---|
| OBS-SEC-001 | 临时凭据 / security token | 未开始 | `Credentials` 现只有永久密钥；V4 头前缀已支持 |
| OBS-CNV-001 | 自动分片 / 断点续传 / 进度回调 | 未开始 | 高层 helper |
| OBS-CNV-002 | TransferManager / 分页器 / 重试策略 | 未开始 | 已有操作级重发，缺高层封装 |

### P3 · 可选模块

| ID | 能力 | 状态 | 备注 |
|---|---|---|---|
| OBS-EXT-001 | POSIX / 并行文件接口 | 未开始 | 独立访问模式，不计入核心对象面 |
| OBS-EXT-002 | 图片处理（`x-image-process`） | 未开始 | 独立扩展模块 |

## 3. 不适用/边界

| 项 | 结论 | 理由 |
|---|---|---|
| Path-style 寻址 | 不适用 | 真端点 path 一律 403 `VirtualHostDomainRequired` |
| SelectObject | 不适用 | 基线 API 目录未列 Select 族；按官方确认后再改 |
| PostObject | 不计入 P0 | 官方 Python SDK 未暴露 PostObject；浏览器表单协议，单列为扩展 |
| 桶创建/删除 | 纳入 P1，但不对 file-storage 门面开放 | 账号级动作 |

## 4. 下一批

1. 现有 16 法真桶已复核（2026-10-22）。
2. `delete_objects`、`upload_part_copy`、`list_multipart_uploads`、对象标签三件、条件请求已真桶绿；其余 `post_object`、存储类回读、CRC64 继续。
3. P0 绿后开 P1 控制面；POSIX/图片处理单独立项。
