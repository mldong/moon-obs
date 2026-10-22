///|
/// 桶配额与存储用量：`PUT/GET /?quota`、`GET /?storageinfo`
/// （官方 Python `client.py:1445-1458` 与 `convertor.py:1468`，2026-10-22 现读）。
/// 配额只设存储量上限；用量读数含总大小与对象数（其余按存储类拆分的不在这一版）。
pub(all) struct BucketStorageInfo {
  size : Int64?
  object_number : Int64?
  body : String
}

///|
pub async fn Client::set_bucket_quota(
  self : Client,
  bucket : String,
  storage_quota : Int64,
) -> Unit raise @error.ObsError {
  let target = bucket
  if storage_quota < 0L {
    raise @error.BadParam("storage quota must be non-negative")
  }
  let document = quota_document(storage_quota)
  let response = request(
    self,
    "PUT",
    target,
    query=[("quota", "")],
    extra_headers=[("content-type", "application/xml")],
    body=@transport.RequestBody::Bytes(@utf8.encode(document.view())),
  )
  discard_body(response)
}

///|
pub async fn Client::get_bucket_quota(
  self : Client,
  bucket : String,
) -> Int64? raise @error.ObsError {
  let target = bucket
  let response = request(self, "GET", target, query=[("quota", "")]) catch {
    err =>
      match err {
        @error.ObsError::Service(details) =>
          if details.status == 404 {
            return None
          } else {
            raise err
          }
        _ => raise err
      }
  }
  let body = response_body_text(response.body, response.status)
  parse_optional_int64(xml_first(body, "StorageQuota"))
}

///|
pub async fn Client::get_bucket_storage_info(
  self : Client,
  bucket : String,
) -> BucketStorageInfo raise @error.ObsError {
  let target = bucket
  let response = request(self, "GET", target, query=[("storageinfo", "")])
  let body = response_body_text(response.body, response.status)
  BucketStorageInfo::{
    size: parse_optional_int64(xml_first(body, "Size")),
    object_number: parse_optional_int64(xml_first(body, "ObjectNumber")),
    body,
  }
}

///|
fn quota_document(storage_quota : Int64) -> String {
  "<Quota><StorageQuota>" +
  storage_quota.to_string() +
  "</StorageQuota></Quota>"
}

///|
fn parse_optional_int64(text : String?) -> Int64? {
  match text {
    None => None
    Some(value) =>
      if value.is_empty() {
        None
      } else {
        Some(@string.parse_int64(value.view(), base=10) catch { _ => 0L })
      }
  }
}
