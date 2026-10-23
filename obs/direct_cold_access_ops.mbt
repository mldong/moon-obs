///|
/// 归档直读：`GET/PUT/DELETE /?directcoldaccess`。华为 OBS 的 XML 根是
/// `DirectColdAccessConfiguration`，只带一个 `Status`（官方 Python
/// `convertor.py:2935-2978`，2026-10-22 现读）；未配置时读口常见 404，落成 `None`。
pub(all) struct DirectColdAccessConfig {
  status : String
}

///|
pub async fn Client::get_bucket_direct_cold_access(
  self : Client,
  bucket : String,
) -> DirectColdAccessConfig? raise @error.ObsError {
  let response = request(self, "GET", bucket, query=[("directcoldaccess", "")]) catch {
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
  Some(DirectColdAccessConfig::{
    status: xml_first(body, "Status").unwrap_or(""),
  })
}

///|
pub async fn Client::put_bucket_direct_cold_access(
  self : Client,
  bucket : String,
  status : String,
) -> Unit raise @error.ObsError {
  if status != "Enabled" && status != "Disabled" {
    raise @error.BadParam(
      "direct cold access status must be Enabled or Disabled, got " + status,
    )
  }
  let document = direct_cold_access_document(status)
  let response = request(
    self,
    "PUT",
    bucket,
    query=[("directcoldaccess", "")],
    extra_headers=[("content-type", "application/xml")],
    body=@transport.RequestBody::Bytes(@utf8.encode(document.view())),
  )
  discard_body(response)
}

///|
pub async fn Client::delete_bucket_direct_cold_access(
  self : Client,
  bucket : String,
) -> Unit raise @error.ObsError {
  let response = request(self, "DELETE", bucket, query=[
    ("directcoldaccess", ""),
  ])
  discard_body(response)
}

///|
fn direct_cold_access_document(status : String) -> String {
  "<DirectColdAccessConfiguration><Status>" +
  xml_escape(status) +
  "</Status></DirectColdAccessConfiguration>"
}
