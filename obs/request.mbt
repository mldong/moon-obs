///|
/// 发一次已签名的请求，并把非 2xx 翻成 `ObsError::Service`。
///
/// **重发这一档只发生在 [send_or_resend]，而那里只覆盖 `send` 那一发**（形状与隔壁
/// moon-hutool 连接池那一档同形："应答前死掉可换新线重发一次，应答阶段失败绝不重试"）：
/// · 拿到**任何** HTTP 状态码都算"应答已到达"，下面的非 2xx 分支一次都不重发，
///   连"读非 2xx 正文时半路断"也不重发（那已是应答之后，重发等于把协议层读数藏起来）；
/// · 重发资格与理由见 [resend_policy]，判定全在 `send` 之前算好。
/// · 两条日志标记词各管一档：`[moon-obs] resending exactly once`（真重发了，至多这一条）与
///   `[moon-obs] NOT resending`（死亡了但按纪律不重发）。数重发就数前者，别把两档混成一档。
///
/// 三处形状与隔壁 `moon-oss` 不同，逐条写在代码旁边：
/// · `host` **要入签、不上请求头**。官方 SDK 的签名头表里就有 host 那一行（AWS SigV4 同形），
///   而 hutool 的 http 端口明确拒绝显式携带 host（"host 由 URL 的 authority 决定"）——
///   于是签的是 transport 按 URL 自己写出去的那一串，两边必须同一个来源：[Config::host_of]。
///   OSS 正相反：把 host 算进头块当场 `SignatureDoesNotMatch`。
/// · **传进来的每个头都签**（OBS 无 allowlist）。所以"进了线的头"与"签进去的头"必须是同一份，
///   少一个就多一个都是 403。这一条不靠注释保证，靠 [request] 里那次实名的比对。
/// · 发出去的查询串用的就是**规范化那一串**（排序后、编码后、空值写成 `k=`）。
///   OBS 的空值参数带等号（`acl=`、`uploads=`），OSS 是无值只写键名——两处各拼一遍迟早各错一半。
async fn request(
  client : Client,
  verb : String,
  bucket : String,
  key~ : String = "",
  query~ : Array[(String, String)] = [],
  extra_headers~ : Array[(String, String)] = [],
  body~ : @transport.RequestBody = @transport.RequestBody::Empty,
) -> @transport.Response raise @error.ObsError {
  let config = client.config
  let millis = @auth.now_millis()
  let timestamp = @auth.iso8601_basic(millis)
  let required = @auth.required_headers(timestamp, prefix=signed_prefix)
  // 两处真相的入口先关死：调用方想自带 host / 必带头 / authorization 一律响亮拒。
  reject_reserved(extra_headers, required)
  let host = config.host_of(bucket)
  // 只把 host 与调用方的头交给签名器；`Credentials::sign_at` 会补上 required 那两头，
  // 补的是**同一份** [required]（同一个 timestamp、同一个前缀），所以线与签不会分叉。
  let signature = config
    .credentials()
    .sign_at(
      config.region_of(),
      millis,
      @auth.RequestToSign::{
        verb,
        canonical_uri: config.canonical_uri_of(bucket, key~),
        query,
        headers: [("host", host)] + extra_headers,
        payload_hash: @auth.unsigned_payload,
      },
      header_prefix=signed_prefix,
    )
  bind_signed_to_wire(signature.signed_headers, required, extra_headers)
  let canonical_query = @auth.canonical_query_string(query)
  let url = config.url_of(bucket, key~)
  let full_url = if canonical_query.is_empty() {
    url
  } else {
    url + "?" + canonical_query
  }
  let wire : Array[@transport.Header] = []
  for pair in required + extra_headers {
    wire.push(@transport.Header::{ name: pair.0, value: pair.1, })
  }
  wire.push(@transport.Header::{
    name: "authorization",
    value: signature.authorization,
  })
  let http_method = method_of(verb)
  // 资格在**发出之前**判完（体能不能倒带、这一档幂不幂等），到了死亡现场只做分支，不临时发明判据。
  let policy = resend_policy(verb, query, body)
  let packet = @transport.Request::{
    http_method,
    url: full_url,
    headers: wire,
    body,
  }
  let response = send_or_resend(
    client,
    policy,
    request_label(verb, bucket, key),
    packet,
  )
  if response.status >= 200 && response.status < 300 {
    response
  } else {
    let body_stream = response.body
    let text = response_body_text(body_stream, response.status)
    raise @error.Service(@error.ServiceError::{
      status: response.status,
      code: xml_error_code(text),
      message: or_empty(xml_first(text, "Message")),
      request_id: request_id_of(response.headers),
    })
  }
}

///|
/// 重发资格。三条判据，顺序固定，判定全部发生在**发出之前**：
/// ① **体不可倒带**（`Stream`）⇒ 一律不重发。半条体发出去过再发一遍，服务端读到的是拼接后的
///    畸形体——重发比失败更坏（隔壁 moon-hutool 适配层 `replayable` 那一格同判据）。
/// ② **POST 一律不重发**。本 SDK 只有两条 POST，都不幂等，且**认不出来的 POST 按不幂等**待：
///   · `POST ?uploads`（建分片任务）重发会多出一个 `uploadId`，前一个没人 abort 就永远漏在桶里；
///   · `POST ?uploadId=`（合并分片）重发可能双份合并／竞态。
/// ③ 只有 **GET／HEAD／PUT／DELETE** 这四档可重发：落点由 (桶, 键, 查询串) 定死，而重发的是
///    **同一发已签名的字节**（同一 uploadId、同一分片号、同一份正文），服务端重复执行与执行一次同果。
///    `PUT` 的"键幂等"含复制那一发（同源同目标再覆写一次）与 `PUT ?acl`。
///
/// 载荷是一句话理由，只供日志，不参与判定。
priv enum Resend {
  Allowed(String)
  Refused(String)
}

///|
/// 流式体给不出"倒带"这件事，所以它一出现就失去重发资格（`Empty`／`Bytes` 都在内存里，可原样再发）。
fn body_replayable(body : @transport.RequestBody) -> Bool {
  match body {
    @transport.RequestBody::Stream(_, _) => false
    @transport.RequestBody::Empty | @transport.RequestBody::Bytes(_) => true
  }
}

///|
fn has_query_key(pairs : Array[(String, String)], want : String) -> Bool {
  let mut found = false
  for pair in pairs {
    if pair.0 == want {
      found = true
    }
  }
  found
}

///|
/// 那一条 POST 具体是哪一档非幂等，日志与诊断都要说得出名字；说不出的一律按最坏的那一档待。
fn post_refusal_reason(query : Array[(String, String)]) -> String {
  if has_query_key(query, "uploads") {
    "POST ?uploads mints a new uploadId, and a resend would leave the first one in the bucket with nobody to abort it"
  } else if has_query_key(query, "uploadId") {
    "POST ?uploadId merges parts, and a resend could merge twice or race the first merge"
  } else {
    "this POST is not on the classified-idempotent list, so it is treated as non-idempotent"
  }
}

///|
fn resend_policy(
  verb : String,
  query : Array[(String, String)],
  body : @transport.RequestBody,
) -> Resend {
  if !body_replayable(body) {
    return Resend::Refused(
      "the request body is a stream and cannot be replayed",
    )
  }
  if verb == "POST" {
    return Resend::Refused(post_refusal_reason(query))
  }
  if verb == "GET" || verb == "HEAD" || verb == "PUT" || verb == "DELETE" {
    return Resend::Allowed(
      "it replays the same signed bytes onto one fixed (bucket, key, query) target",
    )
  }
  Resend::Refused("verb " + verb + " is not on the idempotent list")
}

///|
/// 日志里那一发是谁：**只到键为止，查询串一律不带**。
/// 分片与预签名那一族的凭据本体就在 query 里（`X-Amz-Signature`／`uploadId`），
/// 而重发日志要回答的是"哪一发"——虚主机在同一客户端上恒定，写进去没有增量。
fn request_label(verb : String, bucket : String, key : String) -> String {
  let resource = if bucket.is_empty() {
    "(service root)"
  } else if key.is_empty() {
    "/" + bucket
  } else {
    "/" + bucket + "/" + key
  }
  verb + " " + resource
}

///|
/// 重发那一条日志的**原文**。写成纯函数是有原因的：日志不许只在"跑到了才看得见"，
/// 它得能被断言（测试侧对这一串的形状下判据，生产侧 `println` 的就是同一串）。
fn resend_note(op : String, safety : String, death : String) -> String {
  "[moon-obs] resending exactly once: " +
  op +
  " -- response headers had not arrived (" +
  death +
  "); the resend is safe because " +
  safety
}

///|
/// 不重发那一条日志的**原文**。拒一次也要响亮——"这一发死了但按纪律没再发"与
/// "这一发死了、什么都没发生"在报障时长得一样，只有打出来才分得开。
/// 标记词与 [resend_note] 不同（`NOT resending`），数日志的人要把两档分开数。
fn refusal_note(op : String, reason : String, death : String) -> String {
  "[moon-obs] NOT resending: " +
  op +
  " -- " +
  reason +
  " (the first attempt died before any response header arrived: " +
  death +
  ")"
}

///|
/// 发**一趟**，把"没拿到应答"折成 `(None, 文案)` 而不是抛出去。
/// 注：`expr catch` 的两臂必须同型，重发那条链要靠这个形状才写得出来。
async fn send_attempt(
  client : Client,
  packet : @transport.Request,
) -> (@transport.Response?, String) noraise {
  let response = client.transport.send(packet) catch {
    err => return (None, transport_text(err))
  }
  (Some(response), "")
}

///|
/// 一档就够：**至多重发一次**，且只在"响应头没到达"时、只对幂等档。
/// 第二次仍死亡就把死亡原样交出去——再多趟就是把"公网抖一下"变成"整轮自己重试自己"，
/// 那是 CI 层的活，不是 SDK 的承诺面。
/// 拿到状态码（4xx／5xx 都算应答到达）之后不再有任何重发机会：那一发在这里就返回了。
async fn send_or_resend(
  client : Client,
  policy : Resend,
  op : String,
  packet : @transport.Request,
) -> @transport.Response raise @error.ObsError {
  let first = send_attempt(client, packet)
  match first.0 {
    Some(response) => response
    None =>
      match policy {
        Resend::Refused(reason) => {
          println(refusal_note(op, reason, first.1))
          raise @error.Network(first.1)
        }
        Resend::Allowed(safety) => {
          println(resend_note(op, safety, first.1))
          let second = send_attempt(client, packet)
          match second.0 {
            Some(response) => response
            None => raise @error.Network(second.1)
          }
        }
      }
  }
}

///|
/// 请求号头名：`<prefix>request-id`。真桶回的是 `x-amz-request-id`（V4 那一族的头名），
/// 但两个名字都找一遍——找错名字不会报错，只会让报障时手上没有那串号。
fn request_id_header() -> String {
  signed_prefix.text() + "request-id"
}

///|
fn request_id_of(headers : Array[@transport.Header]) -> String? {
  match header_of(headers, request_id_header()) {
    Some(v) => Some(v)
    None => header_of(headers, "x-obs-request-id")
  }
}

///|
/// 调用方不许手写的那三个名字：`host`（签名另有出处）、`authorization`（它是签名结果的载体，
/// 签名件本身也会拒）、以及 `<prefix>date`／`<prefix>content-sha256`（值由时钟与协议定，
/// 给两份不同的就等于签出去的串与发出去的串不是一条）。
fn reject_reserved(
  extra : Array[(String, String)],
  required : Array[(String, String)],
) -> Unit raise @error.ObsError {
  let reserved : Array[String] = [
    "host",
    "authorization",
    required[0].0,
    required[1].0,
  ]
  for pair in extra {
    let name = pair.0.to_lower()
    for want in reserved {
      if name == want {
        raise @error.BadParam(
          "this header is assembled by the client and must not be passed in: " +
          name,
        )
      }
    }
  }
}

///|
/// "签的头"与"线的头"必须是同一份——这一条是 OBS `传进来的每个头都签` 的直接后果，
/// 也是这一族最难查的错（签名值本身没错、服务端却永远 403）。
/// 这里**独立重算**一遍头名集合再与签名件给的那一串比：两处各写一遍同一条规则才是真危险，
/// 所以比的是"结果"而不是"同一函数的两次调用"。
fn bind_signed_to_wire(
  signed : String,
  required : Array[(String, String)],
  extra : Array[(String, String)],
) -> Unit raise @error.ObsError {
  let names : Array[String] = ["host"]
  for pair in required {
    names.push(pair.0.to_lower())
  }
  for pair in extra {
    names.push(pair.0.to_lower())
  }
  let expected = ascii_join(names)
  if expected != signed {
    raise @error.BadParam(
      "signed headers and wire headers diverged: wire=" +
      expected +
      " signed=" +
      signed,
    )
  }
}

///|
/// 字典序（按 UTF-16 码位逐位比，短串是长串前缀时短的先）、去重、分号连接。
/// 与签名件里那条规则**各自实现**，用来互相对拍。
fn ascii_join(names : Array[String]) -> String {
  let ordered : Array[String] = []
  for name in names {
    if !has_name(ordered, name) {
      let mut placed = false
      let mut index = 0
      while index < ordered.length() && !placed {
        if less_ascii(name, ordered[index]) {
          placed = true
        } else {
          index = index + 1
        }
      }
      ordered.insert(index, name)
    }
  }
  let mut out = ""
  for i in 0..<ordered.length() {
    if i > 0 {
      out = out + ";"
    }
    out = out + ordered[i]
  }
  out
}

///|
/// 本版 `Array[String]` 没有 `index_of`，去重就自己扫一遍（个位数长度）。
fn has_name(names : Array[String], want : String) -> Bool {
  let mut found = false
  for name in names {
    if name == want {
      found = true
    }
  }
  found
}

///|
fn less_ascii(a : String, b : String) -> Bool {
  let ac = a.to_array()
  let bc = b.to_array()
  let n = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  let mut i = 0
  while i < n {
    let x = ac[i].to_int()
    let y = bc[i].to_int()
    if x < y {
      return true
    }
    if x > y {
      return false
    }
    i = i + 1
  }
  ac.length() < bc.length()
}

///|
fn method_of(verb : String) -> @transport.Method raise @error.ObsError {
  match verb {
    "GET" => @transport.Method::Get
    "HEAD" => @transport.Method::Head
    "PUT" => @transport.Method::Put
    "POST" => @transport.Method::Post
    "DELETE" => @transport.Method::Delete
    _ => raise @error.BadParam("unsupported verb: " + verb)
  }
}

///|
/// 问号之后一律隐去。传输层的 `InvalidRequest` 有几档会把整条 URL 原样写进文案
/// （hutool 的 `split_url`：`url 缺 :// 分隔`、`url 带 fragment`、`url 缺 authority`、
/// `pathless query` 四档都带），而预签名 URL 的 query **就是凭据本体**——
/// `X-Amz-Credential` 加一条窗口内可用的 `X-Amz-Signature`，落进日志等于把这条授权
/// 又发出去一份。主机与路径留着：诊断要看的是"哪一发"，不是那把钥匙。
fn redact_query(text : String) -> String {
  match text.find("?") {
    None => text
    Some(at) => text[0:at].to_owned() + "?<redacted>"
  }
}

///|
/// 生产件里把传输层文案交给调用方的唯一通道：`request` 与 `read_all` 两个 catch 点都走这里。
/// 新加 catch 点时别再手写 `"network: " + detail`。
fn transport_text(err : @transport.TransportError) -> String {
  match err {
    @transport.TransportError::Network(detail) =>
      "network: " + redact_query(detail)
    @transport.TransportError::Timeout => "timeout"
    @transport.TransportError::InvalidRequest(detail) =>
      "invalid request: " + redact_query(detail)
    @transport.TransportError::InvalidResponse(detail) =>
      "invalid response: " + redact_query(detail)
  }
}

///|
fn or_empty(value : String?) -> String {
  match value {
    Some(v) => v
    None => ""
  }
}

///|
fn header_of(headers : Array[@transport.Header], name : String) -> String? {
  let want = name.to_lower()
  for h in headers {
    if h.name.to_lower() == want {
      return Some(h.value)
    }
  }
  None
}

///|
/// 把响应体读空。非 2xx 的分支也要读，否则除了状态码什么证据都没有。
async fn read_all(
  body : &@transport.ResponseBody,
) -> Bytes raise @error.ObsError {
  let merged : Array[Byte] = []
  let mut reading = true
  while reading {
    let chunk = body.read(65536) catch {
      err => raise @error.Network(transport_text(err))
    }
    match chunk {
      Some(data) => merged.append(data.to_array())
      None => reading = false
    }
  }
  Bytes::from_array(merged)
}

///|
/// 本 SDK 全量读回的正文都按 UTF-8 解；解不开不是"网络断"也不是"服务端拒"，
/// 是这条应答本身没法用，所以单列 `BadResponse`，并把状态码带在文案里。
fn response_text(data : Bytes, status : Int32) -> String raise @error.ObsError {
  @utf8.decode(data.exact_view()) catch {
    _ =>
      raise @error.BadResponse(
        "response body is not valid UTF-8, status " + status.to_string(),
      )
  }
}

///|
/// 读完并关掉响应体。**2xx 且不需要正文的那几条都必须走这一条**：
/// 传输层的池只收"读尽的线"，不读也不关等于把一条 TLS 连接晾在外面——
/// 隔壁 `moon-oss` 真桶实测过，晾着的连接会让后面的请求整等 30 秒再报 timeout。
async fn discard_body(
  response : @transport.Response,
) -> Unit raise @error.ObsError {
  let body = response.body
  let _ = read_all(body)
  body.close()
}

///|
/// 成功分支的正文读数：调用方只要文本（列举、拷贝回执、分片回执）。
async fn response_body_text(
  body : &@transport.ResponseBody,
  status : Int32,
) -> String raise @error.ObsError {
  let raw = read_all(body)
  body.close()
  response_text(raw, status)
}
