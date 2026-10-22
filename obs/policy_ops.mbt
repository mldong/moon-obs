///|
/// 桶 Policy：`GET/PUT/DELETE /?policy`。华为 OBS 的 `setBucketPolicy` 收原始 JSON 文档
/// （官方 Python `client.py:1477-1490`，2026-10-22 现读）；未配置时读口回 404，落成 `None`。
pub async fn Client::put_bucket_policy(
  self : Client,
  bucket : String,
  policy : String,
) -> Unit raise @error.ObsError {
  if policy.is_empty() {
    raise @error.BadParam("put_bucket_policy needs a non-empty policy document")
  }
  let response = request(
    self,
    "PUT",
    bucket,
    query=[("policy", "")],
    extra_headers=[("content-type", "application/json")],
    body=@transport.RequestBody::Bytes(@utf8.encode(policy.view())),
  )
  discard_body(response)
}

///|
pub async fn Client::get_bucket_policy(
  self : Client,
  bucket : String,
) -> String? raise @error.ObsError {
  let response = request(self, "GET", bucket, query=[("policy", "")]) catch {
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
  Some(response_body_text(response.body, response.status))
}

///|
pub async fn Client::delete_bucket_policy(
  self : Client,
  bucket : String,
) -> Unit raise @error.ObsError {
  let response = request(self, "DELETE", bucket, query=[("policy", "")])
  discard_body(response)
}
