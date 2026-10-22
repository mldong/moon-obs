///|
/// OBS 的三个对象级维护操作：重命名、截断、指定位置改写。
/// 路径逐条照官方 Python SDK `client.py`（2026-10-22 现读）：
/// - `renameFile`  `POST /<key>?rename&name=<新键>`（`:1783`）
/// - `modifyFile`  `PUT /<key>?modify&position=<n>`，正文是要写进去的片段（`:1790`）
/// - `truncateFile` `PUT /<key>?truncate&length=<n>`（`:1826`）
/// **截断与改写是 POSIX 桶专属**：官方集成测试都先建 `isPFS=True` 的桶，普通桶实测
/// 405 MethodNotAllowed（2026-10-22 真桶读数）。重命名在普通桶可用并已真桶验证。
pub async fn Client::rename_object(
  self : Client,
  bucket : String,
  key : String,
  new_key : String,
) -> Unit raise @error.ObsError {
  if new_key.is_empty() {
    raise @error.BadParam("rename_object needs a new key")
  }
  let response = request(self, "POST", bucket, key~, query=[
    ("rename", ""),
    ("name", new_key),
  ])
  discard_body(response)
}

///|
pub async fn Client::truncate_object(
  self : Client,
  bucket : String,
  key : String,
  length : Int64,
) -> Unit raise @error.ObsError {
  if length < 0L {
    raise @error.BadParam("truncate length must be non-negative")
  }
  let response = request(self, "PUT", bucket, key~, query=[
    ("truncate", ""),
    ("length", length.to_string()),
  ])
  discard_body(response)
}

///|
/// `position` 从 0 起算；`content` 为空时就是一次纯位置校验（服务端仍会走这一发）。
pub async fn Client::modify_object(
  self : Client,
  bucket : String,
  key : String,
  position : Int64,
  content : Bytes,
) -> Unit raise @error.ObsError {
  if position < 0L {
    raise @error.BadParam("modify position must be non-negative")
  }
  let response = request(
    self,
    "PUT",
    bucket,
    key~,
    query=[("modify", ""), ("position", position.to_string())],
    body=@transport.RequestBody::Bytes(content),
  )
  discard_body(response)
}
