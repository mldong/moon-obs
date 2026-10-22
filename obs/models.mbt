///|
/// 对象族与 ACL 的读数形状。刻意做窄：只带这条线（文件存储契约）真要用的字段——
/// `etag`／`size`／`last_modified`／`content_type`／`metadata`。
/// OBS 响应头还有二十几项，全抄进来就等于承诺维护一份与协议同宽的面。

///|
pub(all) struct PutObjectResult {
  etag : String
}

///|
pub(all) struct ObjectData {
  content_length : Int64
  content_type : String?
  /// 只回元数据头那几项（键名已去掉 `<prefix>meta-` 前缀），与 `metadata~` 入参同一坐标系
  metadata : Array[(String, String)]
  content_range : String?
  etag : String?
  /// 正文已整段读回。范围档与整读档共用这一格，因为调用方是要 bytes 的
  body : Bytes
}

///|
pub(all) struct ObjectInfo {
  key : String
  etag : String?
  size : Int64
  last_modified : String?
  storage_class : String?
}

///|
/// `HEAD /<key>` 的读数。与列举行那一格 `ObjectInfo` 分开定：这一族要带元数据与
/// content-type，而列举回包里根本没有它们。
pub(all) struct ObjectStat {
  key : String
  etag : String?
  size : Int64
  last_modified : String?
  content_type : String?
  storage_class : String?
  /// 只回元数据头那几项（键名已去掉 `<prefix>meta-` 前缀），与 `metadata~` 入参同一坐标系
  metadata : Array[(String, String)]
}

///|
pub(all) struct ObjectListing {
  objects : Array[ObjectInfo]
  /// `delimiter` 折叠出来的"目录"，与 objects 同一次回包、同一坐标系
  common_prefixes : Array[String]
  is_truncated : Bool
  /// V1 形态的续页游标（服务端给的 `NextMarker`；没给就是"到底了"或"没带 delimiter"）
  next_marker : String?
  /// 回包原文。解析件只取简单形状，读不出的形状要能回查
  body : String
}

///|
pub(all) struct CopyResult {
  etag : String
  body : String
}

///|
/// 批量删除里单条失败。成功与失败按 `<Deleted>` / `<Error>` 两族分开收。
pub(all) struct DeleteObjectFailure {
  key : String
  code : String
  message : String
}

///|
/// `POST /?delete` 的读数。`quiet=true` 时服务端可以不回正文。
pub(all) struct DeleteObjectsResult {
  deleted : Array[String]
  errors : Array[DeleteObjectFailure]
  body : String
}

///|
/// `UploadPartCopy` 的读数。
pub(all) struct UploadPartCopyResult {
  etag : String
  last_modified : String?
  body : String
}

///|
/// 一条未完成的分片任务。
pub(all) struct MultipartUploadInfo {
  key : String
  upload_id : String
  initiated : String?
}

///|
/// `GET /?uploads` 的一页。
pub(all) struct MultipartUploadListing {
  uploads : Array[MultipartUploadInfo]
  common_prefixes : Array[String]
  is_truncated : Bool
  next_key_marker : String?
  next_upload_id_marker : String?
  body : String
}

///|
/// 对象标签的一对键值。OBS 上限 10 对，键在对象内唯一。
pub(all) struct ObjectTag {
  key : String
  value : String
}

///|
/// `GET /<key>?tagging` 的读数。
pub(all) struct ObjectTagging {
  tags : Array[ObjectTag]
  body : String
}

///|
/// `POST /<key>?append&position=N` 的读数。
pub(all) struct AppendResult {
  next_position : Int64?
  etag : String?
  body : String
}

///|
pub(all) struct PartInfo {
  part_number : Int32
  etag : String
  size : Int64
}

///|
pub(all) struct PartPage {
  parts : Array[PartInfo]
  is_truncated : Bool
  /// 续页用的分片号；回包没给就是"到底了"
  next_part_number_marker : String?
  body : String
}

///|
/// 一条授权。字段按**回体里真实存在的元素**定，不按文档里的理想形状定：
/// OBS 的 `<Grantee>` 靠 `xsi:type` 属性分档（组授权给 `<URI>`、账号授权给 `<ID>`，
/// 邮件地址那一族在 OBS 没出现过），所以四格都可空、读回来是什么就是什么。
pub(all) struct Grant {
  /// `Grantee` 上 `xsi:type` 的读数（`Group`／`CanonicalUser`／…），读不到是空串
  grantee_type : String
  grantee_id : String?
  grantee_uri : String?
  grantee_email : String?
  /// `READ`／`WRITE`／`READ_ACP`／`WRITE_ACP`／`FULL_CONTROL`
  permission : String
}

///|
/// `GET /<key>?acl=` 的回包读数。
/// `owner_id` 是账号标识、不是密钥，但也不进日志——打印请只报长度。
pub(all) struct ObjectAcl {
  grants : Array[Grant]
  owner_id : String?
  /// 回体根元素声明的命名空间（读数本身；解析靠局部名，不靠它）。
  /// 字段名不叫 `namespace`——那是本版的保留字。
  default_ns : String?
  body : String
}
