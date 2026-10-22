///|
/// 服务级与桶级列举两条。
///
/// 桶级列举走的是 **ListObjects V1**（`marker`／`NextMarker`）。为什么不是 V2：
/// 官方参照实现（Python SDK 全文）搜不到 `list-type`，而"真端点吃不吃某个参数"
/// 与"这条行为有没有参照实现"是两件事——`list-type=2` 在原生面收不收由
/// `live_test.mbt` 那档实测并打印，**但收下也不写进承诺面**（同 `moon-cos` 对
/// `q-sign-algorithm=sha256` 的处置）。没有参照实现的行为不实现。

///|
pub(all) struct BucketListing {
  names : Array[String]
  /// 回包原文。解析件只取简单形状，读不出的形状要能回查
  body : String
}

///|
/// 服务级 `GET /`：列这把凭据名下的桶。空桶名走的就是这条（[Config::host_of] 不给桶前缀）。
pub async fn Client::list_buckets(
  self : Client,
) -> BucketListing raise @error.ObsError {
  let response = request(self, "GET", "")
  let body = response_body_text(response.body, response.status)
  // `<Name>` 在 `ListAllMyBucketsResult` 里是桶名，但 Owner 那一族也叫 `Name`——
  // 不切段就会把" DisplayName"当成一个桶。先按 `<Bucket>` 切段再段内取 Name。
  let names : Array[String] = []
  for section in xml_sections(body, "Bucket") {
    names.push(or_empty(xml_first(section, "Name")))
  }
  BucketListing::{ names, body, }
}

///|
/// 建桶。账号级动作，不接 `moon-file-storage` 门面；`acl`/`storage_class` 为空就不发头。
pub async fn Client::create_bucket(
  self : Client,
  bucket : String,
  acl~ : String = "",
  storage_class~ : String = "",
) -> Unit raise @error.ObsError {
  if bucket.is_empty() {
    raise @error.BadParam("create_bucket needs a bucket name")
  }
  let response = request(
    self,
    "PUT",
    bucket,
    extra_headers=bucket_admin_headers(acl~, storage_class~),
  )
  discard_body(response)
}

///|
pub async fn Client::delete_bucket(
  self : Client,
  bucket : String,
) -> Unit raise @error.ObsError {
  if bucket.is_empty() {
    raise @error.BadParam("delete_bucket needs a bucket name")
  }
  let response = request(self, "DELETE", bucket)
  discard_body(response)
}

///|
/// 只读判断：2xx 为真，404 为假；其余错误原样抛。
pub async fn Client::bucket_exists(
  self : Client,
  bucket : String,
) -> Bool raise @error.ObsError {
  if bucket.is_empty() {
    raise @error.BadParam("bucket_exists needs a bucket name")
  }
  let response = request(self, "HEAD", bucket) catch {
    err =>
      match err {
        @error.ObsError::Service(details) =>
          if details.status == 404 {
            return false
          } else {
            raise err
          }
        _ => raise err
      }
  }
  discard_body(response)
  true
}

///|
fn bucket_admin_headers(
  acl~ : String,
  storage_class~ : String,
) -> Array[(String, String)] {
  let headers : Array[(String, String)] = []
  if !acl.is_empty() {
    headers.push((acl_header_name(), acl))
  }
  if !storage_class.is_empty() {
    headers.push((signed_prefix.text() + "storage-class", storage_class))
  }
  headers
}

///|
/// 桶级列举（V1）。`marker`／`max-keys`／`prefix`／`delimiter` 全部进签名串——
/// OBS 的规范化查询串按原始键排序、空值也写成 `k=`，这一条真端点不认的话
/// 这里当场 `SignatureDoesNotMatch`，不会静默通过。
///
/// 一行对象要同时读 `Key`／`Size`／`ETag`／`LastModified`，所以按 `<Contents>` **切段**
/// 再段内取值。把 `xml_all("Key")` 与 `xml_all("Size")` 各取一次再按下标配，
/// 遇到某个字段缺失的回包就会整体错位。
pub async fn Client::list_objects(
  self : Client,
  bucket : String,
  prefix~ : String = "",
  delimiter~ : String = "",
  max_keys~ : Int32 = 1000,
  marker~ : String = "",
) -> ObjectListing raise @error.ObsError {
  let query : Array[(String, String)] = [("max-keys", max_keys.to_string())]
  add_param(query, "prefix", prefix)
  add_param(query, "delimiter", delimiter)
  add_param(query, "marker", marker)
  let response = request(self, "GET", bucket, query~)
  let body = response_body_text(response.body, response.status)
  let objects : Array[ObjectInfo] = []
  for section in xml_sections(body, "Contents") {
    objects.push(ObjectInfo::{
      key: or_empty(xml_first(section, "Key")),
      etag: xml_first(section, "ETag"),
      size: parse_int64(or_empty(xml_first(section, "Size"))),
      last_modified: xml_first(section, "LastModified"),
      storage_class: xml_first(section, "StorageClass"),
    })
  }
  // `<Prefix>` 在 ListBucketResult 里也出现一次（回显请求的 prefix），而 CommonPrefixes
  // 那族同样是 `<Prefix>`——不切段就会把回显的那一条当成一个"目录"。
  let prefixes : Array[String] = []
  for group in xml_sections(body, "CommonPrefixes") {
    prefixes.push(or_empty(xml_first(group, "Prefix")))
  }
  ObjectListing::{
    objects,
    common_prefixes: prefixes,
    is_truncated: or_empty(xml_first(body, "IsTruncated")) == "true",
    next_marker: xml_first(body, "NextMarker"),
    body,
  }
}

///|
/// 值为空的参数不进查询串：`prefix=""` 与"没有 prefix"在签名上是两件事（前者签出
/// `prefix=`，后者根本不入签），发错了会让签名与 URL 两处各错一半。
fn add_param(
  query : Array[(String, String)],
  name : String,
  value : String,
) -> Unit {
  if !value.is_empty() {
    query.push((name, value))
  }
}
