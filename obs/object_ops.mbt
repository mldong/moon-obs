///|
/// 对象族：写、读、查、删、同平台复制。OBS 的用户元数据只有 `<prefix>meta-*` 这一族，
/// 写进去与读回来用的是同一批头（前缀只由 [meta_header_prefix] 一处派生，
/// 真桶口径那一族是 `x-amz-meta-*`，读数与判据在 [signed_prefix] 那段）。

///|
/// `metadata~` 里的键名**不带** `<prefix>meta-` 前缀：前缀是本协议的固定部分，
/// 让调用方重复写一遍只会多出"写了两次前缀"这一类错。
pub async fn Client::put_object(
  self : Client,
  bucket : String,
  key : String,
  data : Bytes,
  content_type~ : String = "",
  metadata~ : Array[(String, String)] = [],
  acl~ : String = "",
  storage_class~ : String = "",
  content_md5~ : String = "",
  compute_md5~ : Bool = false,
  if_match~ : String = "",
  if_none_match~ : String = "",
) -> PutObjectResult raise @error.ObsError {
  if compute_md5 && !content_md5.is_empty() {
    raise @error.BadParam("content_md5 and compute_md5 are mutually exclusive")
  }
  let md5 = if compute_md5 { content_md5_of(data) } else { content_md5 }
  let response = request(
    self,
    "PUT",
    bucket,
    key~,
    extra_headers=object_headers(
        content_type~,
        metadata~,
        acl~,
        copy_source="",
        storage_class~,
        content_md5=md5,
      ) +
      conditional_headers(if_match~, if_none_match~),
    body=@transport.RequestBody::Bytes(data),
  )
  discard_body(response)
  PutObjectResult::{ etag: or_empty(header_of(response.headers, "etag")), }
}

///|
/// 读对象。`range~` 给的是 HTTP Range 的原值（如 `bytes=0-3`），本 SDK 不翻译它——
/// 翻译一次就多一处与真端点理解不一致的地方。
pub async fn Client::get_object(
  self : Client,
  bucket : String,
  key : String,
  range~ : String = "",
  if_match~ : String = "",
  if_none_match~ : String = "",
  if_modified_since~ : String = "",
  if_unmodified_since~ : String = "",
) -> ObjectData raise @error.ObsError {
  let extra = conditional_headers(
    if_match~,
    if_none_match~,
    if_modified_since~,
    if_unmodified_since~,
  )
  if !range.is_empty() {
    extra.push(("range", range))
  }
  let response = request(self, "GET", bucket, key~, extra_headers=extra)
  let body = read_all(response.body)
  response.body.close()
  ObjectData::{
    content_length: parse_int64(
      or_empty(header_of(response.headers, "content-length")),
    ),
    content_type: header_of(response.headers, "content-type"),
    metadata: meta_pairs(response.headers),
    content_range: header_of(response.headers, "content-range"),
    etag: header_of(response.headers, "etag"),
    body,
  }
}

///|
/// `HEAD /<key>`：只查不取。回 `NotFound` 档还是回 `Service` 档由调用方按状态码判——
/// 这一层不替业务决定"不存在"算不算错。
pub async fn Client::stat_object(
  self : Client,
  bucket : String,
  key : String,
  if_match~ : String = "",
  if_none_match~ : String = "",
  if_modified_since~ : String = "",
  if_unmodified_since~ : String = "",
) -> ObjectStat raise @error.ObsError {
  let response = request(
    self,
    "HEAD",
    bucket,
    key~,
    extra_headers=conditional_headers(
      if_match~,
      if_none_match~,
      if_modified_since~,
      if_unmodified_since~,
    ),
  )
  discard_body(response)
  ObjectStat::{
    key,
    etag: header_of(response.headers, "etag"),
    size: parse_int64(or_empty(header_of(response.headers, "content-length"))),
    last_modified: header_of(response.headers, "last-modified"),
    content_type: header_of(response.headers, "content-type"),
    storage_class: header_of(response.headers, "x-amz-storage-class"),
    metadata: meta_pairs(response.headers),
  }
}

///|
pub async fn Client::delete_object(
  self : Client,
  bucket : String,
  key : String,
  if_match~ : String = "",
) -> Unit raise @error.ObsError {
  let response = request(
    self,
    "DELETE",
    bucket,
    key~,
    extra_headers=conditional_headers(if_match~, if_none_match=""),
  )
  discard_body(response)
}

///|
/// 同平台复制。头名是 `<prefix>copy-source`（由 [signed_prefix] 派生，不是 S3 那族的
/// `x-amz-copy-source`），值是 `/<源桶>/<源键>` 且**键要按 URI 编码**：参照实现的
/// `trans_copy_object` 给的是原值，但原值里带空格／非 ASCII 时线格式装不下，
/// 而真端点会把它解码回来——编码后的那一份才是两边都认的。
/// 这一头属于 `<prefix>-*` 族，必然入签（OBS 无 allowlist）。
pub async fn Client::copy_object(
  self : Client,
  source_bucket : String,
  source_key : String,
  bucket : String,
  key : String,
  metadata~ : Array[(String, String)] = [],
  storage_class~ : String = "",
  copy_source_if_match~ : String = "",
  copy_source_if_none_match~ : String = "",
  copy_source_if_modified_since~ : String = "",
  copy_source_if_unmodified_since~ : String = "",
) -> CopyResult raise @error.ObsError {
  let source = "/" + source_bucket + "/" + @auth.encode_object_key(source_key)
  let response = request(
    self,
    "PUT",
    bucket,
    key~,
    extra_headers=object_headers(
        content_type="",
        metadata~,
        acl="",
        copy_source=source,
        storage_class~,
      ) +
      copy_source_conditional_headers(
        if_match=copy_source_if_match,
        if_none_match=copy_source_if_none_match,
        if_modified_since=copy_source_if_modified_since,
        if_unmodified_since=copy_source_if_unmodified_since,
      ),
  )
  let body = response_body_text(response.body, response.status)
  CopyResult::{ etag: or_empty(xml_first(body, "ETag")), body, }
}

///|
/// 组装对象族那一族请求头。空值的头**不进数组**：签名头块里多一行空的元数据头
/// 就会与参照实现算出的规范化串差一行，而线格式上那一行也是没意义的。
fn object_headers(
  content_type~ : String = "",
  metadata~ : Array[(String, String)] = [],
  acl~ : String = "",
  copy_source~ : String = "",
  storage_class~ : String = "",
  content_md5~ : String = "",
) -> Array[(String, String)] {
  let headers : Array[(String, String)] = []
  if !content_type.is_empty() {
    headers.push(("content-type", content_type))
  }
  if !acl.is_empty() {
    headers.push((acl_header_name(), acl))
  }
  if !copy_source.is_empty() {
    headers.push((copy_source_header_name(), copy_source))
  }
  if !storage_class.is_empty() {
    headers.push((signed_prefix.text() + "storage-class", storage_class))
  }
  if !content_md5.is_empty() {
    headers.push(("content-md5", content_md5))
  }
  for pair in metadata {
    headers.push((meta_header_prefix() + pair.0, pair.1))
  }
  headers
}

///|
fn content_md5_of(data : Bytes) -> String {
  @base64.encode(@digest.md5_of_bytes(data).exact_view())
}

///|
fn conditional_headers(
  if_match~ : String = "",
  if_none_match~ : String = "",
  if_modified_since~ : String = "",
  if_unmodified_since~ : String = "",
) -> Array[(String, String)] raise @error.ObsError {
  if !if_match.is_empty() && !if_none_match.is_empty() {
    raise @error.BadParam("if_match and if_none_match are mutually exclusive")
  }
  if !if_modified_since.is_empty() && !if_unmodified_since.is_empty() {
    raise @error.BadParam(
      "if_modified_since and if_unmodified_since are mutually exclusive",
    )
  }
  let headers : Array[(String, String)] = []
  if !if_match.is_empty() {
    headers.push(("if-match", if_match))
  }
  if !if_none_match.is_empty() {
    headers.push(("if-none-match", if_none_match))
  }
  if !if_modified_since.is_empty() {
    headers.push(("if-modified-since", if_modified_since))
  }
  if !if_unmodified_since.is_empty() {
    headers.push(("if-unmodified-since", if_unmodified_since))
  }
  headers
}

///|
fn copy_source_conditional_headers(
  if_match~ : String,
  if_none_match~ : String,
  if_modified_since~ : String,
  if_unmodified_since~ : String,
) -> Array[(String, String)] raise @error.ObsError {
  if !if_match.is_empty() && !if_none_match.is_empty() {
    raise @error.BadParam(
      "copy source if_match and if_none_match are mutually exclusive",
    )
  }
  if !if_modified_since.is_empty() && !if_unmodified_since.is_empty() {
    raise @error.BadParam(
      "copy source if_modified_since and if_unmodified_since are mutually exclusive",
    )
  }
  let headers : Array[(String, String)] = []
  if !if_match.is_empty() {
    headers.push((signed_prefix.text() + "copy-source-if-match", if_match))
  }
  if !if_none_match.is_empty() {
    headers.push(
      (signed_prefix.text() + "copy-source-if-none-match", if_none_match),
    )
  }
  if !if_modified_since.is_empty() {
    headers.push(
      (
        signed_prefix.text() + "copy-source-if-modified-since",
        if_modified_since,
      ),
    )
  }
  if !if_unmodified_since.is_empty() {
    headers.push(
      (
        signed_prefix.text() + "copy-source-if-unmodified-since",
        if_unmodified_since,
      ),
    )
  }
  headers
}

///|
/// 把响应头里的元数据族收回来并去掉前缀，与 `metadata~` 入参同一坐标系。
fn meta_pairs(headers : Array[@transport.Header]) -> Array[(String, String)] {
  let prefix = meta_header_prefix()
  let cut = prefix.length()
  let out : Array[(String, String)] = []
  for h in headers {
    let name = h.name.to_lower()
    if name.has_prefix(prefix) {
      out.push((name[cut:name.length()].to_owned(), h.value))
    }
  }
  out
}

///|
/// `0` 是"读不出"的哨兵而不是"大小是 0"：调用侧要真读数就看回包原文，
/// 这里不静默造一个像真值的默认值。
fn parse_int64(text : String) -> Int64 {
  @string.parse_int64(text.view(), base=10) catch {
    _ => 0L
  }
}
