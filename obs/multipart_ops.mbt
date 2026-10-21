///|
/// 手动分片族五步。这条线与"整对象一次写"是两套服务端形状，所以两边要分开测。
///
/// **本层不校验分片最小尺寸**，这是刻意的：官方文档另有"除最后一片外每片不得小于
/// 100KB"的说法，而兼容面实测**不校验**（100KiB 非末片 + 1KiB 末片也 COMPLETE 200）。
/// 客户端替服务端把关会把"服务端到底校不校"这一格永远读成"不知道"，所以把小片原样发上去，
/// 让真端点回话——`live_test.mbt` 里那档就是量这个的。

///|
pub async fn Client::create_multipart_upload(
  self : Client,
  bucket : String,
  key : String,
  content_type~ : String = "",
  metadata~ : Array[(String, String)] = [],
) -> String raise @error.ObsError {
  let response = request(
    self,
    "POST",
    bucket,
    key~,
    // `uploads` 是无值参数——OBS 的规范化查询串把它写成 `uploads=`（带等号）。
    // 这一族与 OSS 反着来（OSS 是无值只写键名），照抄那边当场签名不符。
    query=[("uploads", "")],
    extra_headers=object_headers(content_type~, metadata~),
  )
  let body = response_body_text(response.body, response.status)
  match xml_first(body, "UploadId") {
    Some(id) =>
      if id.is_empty() {
        raise @error.BadResponse(
          "initiate response has an empty UploadId: " + body,
        )
      } else {
        id
      }
    None =>
      raise @error.BadResponse("initiate response carries no UploadId: " + body)
  }
}

///|
/// 分片号从 1 起。越界在**发出请求之前**拒：让服务端去猜一个 0 号分片，
/// 收到的会是一条看不出根因的错。
pub async fn Client::upload_part(
  self : Client,
  bucket : String,
  key : String,
  upload_id : String,
  part_number : Int32,
  data : Bytes,
) -> String raise @error.ObsError {
  if part_number < 1 || part_number > 10000 {
    raise @error.BadParam(
      "part number must be within 1..10000, got " + part_number.to_string(),
    )
  }
  if upload_id.is_empty() {
    raise @error.BadParam("upload id is required")
  }
  let response = request(
    self,
    "PUT",
    bucket,
    key~,
    query=[("partNumber", part_number.to_string()), ("uploadId", upload_id)],
    body=@transport.RequestBody::Bytes(data),
  )
  discard_body(response)
  match header_of(response.headers, "etag") {
    Some(etag) => etag
    None => raise @error.BadResponse("upload_part reply has no ETag header")
  }
}

///|
pub async fn Client::list_parts(
  self : Client,
  bucket : String,
  key : String,
  upload_id : String,
  part_number_marker~ : Int32 = 0,
) -> PartPage raise @error.ObsError {
  if upload_id.is_empty() {
    raise @error.BadParam("upload id is required")
  }
  let query : Array[(String, String)] = [("uploadId", upload_id)]
  if part_number_marker > 0 {
    query.push(("part-number-marker", part_number_marker.to_string()))
  }
  let response = request(self, "GET", bucket, key~, query~)
  let body = response_body_text(response.body, response.status)
  let parts : Array[PartInfo] = []
  for section in xml_sections(body, "Part") {
    parts.push(PartInfo::{
      part_number: parse_int32(or_empty(xml_first(section, "PartNumber"))),
      etag: or_empty(xml_first(section, "ETag")),
      size: parse_int64(or_empty(xml_first(section, "Size"))),
    })
  }
  PartPage::{
    parts,
    is_truncated: or_empty(xml_first(body, "IsTruncated")) == "true",
    next_part_number_marker: xml_first(body, "NextPartNumberMarker"),
    body,
  }
}

///|
/// 完成：分片必须**按号升序**列出。顺序这里不重新排——排了就会把"调用方给的顺序不对"
/// 这个真错藏起来。
pub async fn Client::complete_multipart_upload(
  self : Client,
  bucket : String,
  key : String,
  upload_id : String,
  parts : Array[(Int32, String)],
) -> String raise @error.ObsError {
  if parts.is_empty() {
    raise @error.BadParam("complete needs at least one part")
  }
  if upload_id.is_empty() {
    raise @error.BadParam("upload id is required")
  }
  let response = request(
    self,
    "POST",
    bucket,
    key~,
    query=[("uploadId", upload_id)],
    extra_headers=[("content-type", "application/xml")],
    body=@transport.RequestBody::Bytes(
      @utf8.encode(complete_document(parts).view()),
    ),
  )
  let body = response_body_text(response.body, response.status)
  or_empty(xml_first(body, "ETag"))
}

///|
pub async fn Client::abort_multipart_upload(
  self : Client,
  bucket : String,
  key : String,
  upload_id : String,
) -> Unit raise @error.ObsError {
  if upload_id.is_empty() {
    raise @error.BadParam("upload id is required")
  }
  let response = request(self, "DELETE", bucket, key~, query=[
    ("uploadId", upload_id),
  ])
  discard_body(response)
}

///|
/// 完成件正文。`<CompleteMultipartUpload>` 不带命名空间：请求体由我们写，
/// OBS 服务端读的是元素名而不是命名空间，多写一行声明只会让 Content-MD5 那类校验更难对齐。
fn complete_document(parts : Array[(Int32, String)]) -> String {
  let mut out = "<CompleteMultipartUpload>"
  for pair in parts {
    let number = pair.0.to_string()
    let quoted = xml_escape(pair.1)
    out = out +
      "<Part><PartNumber>" +
      number +
      "</PartNumber><ETag>" +
      quoted +
      "</ETag></Part>"
  }
  out + "</CompleteMultipartUpload>"
}

///|
fn parse_int32(text : String) -> Int32 {
  @string.parse_int(text.view(), base=10) catch {
    _ => 0
  }
}
