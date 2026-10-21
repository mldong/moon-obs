///|
// 真桶档（凭据只从环境读，**绝不打印值**）。这一档才是本卡 §2.3 三条待实测项的裁决处：
// 签名向量只能证明"我算得自洽"，真端点才证明"OBS 原生面认这一套"。
//
// Env: OBS_AK / OBS_SK / OBS_BUCKET / OBS_REGION（外加 `OBS_RUN_TAG` 决定本轮前缀，
// 口径与 hub 的 `scripts/moonfs-gate-env.sh` 一致）。缺前四项任何一项整段响亮跳过。
//
// 写只落 `moonfs-live-<YYYYMMDD>/obs-native-<运行号>-<档名>-*` 这一条**本轮独占**的前缀。
// 清扫纪律（2026-10-19 任务 #73 起）：每一档**开头**先把自家前缀扫一遍（把上一轮这一档
// 中途红掉留下的残留删掉），测量段整段包在 try/catch 里折成读数，**结尾清扫排在断言之前**
// （中途红也把对象删干净再判红），最后才把测量阶段的红原样交出去——判据一条不放宽。
// 为什么不用 `defer`：阶段 B 卡 §7-5 记着"`defer` 能不能放 async 调用仍未验"，
// 那里的正解写的就是"改成用例开头清扫自己前缀"，这里照它做，不引入未验证的语义。
// 为什么每档各扫各的子前缀：wasm 跑批里同包的 async 用例是**并发**的（上一轮的输出就是
// 穿插着的），共用一条前缀会让一档的清扫删掉另一档正在用的对象。
// 存量对象只读不写。
//
// 与隔壁 `moon-oss`／`moon-cos` 的 live 档同一姿势：**读数一律 println 出来**，
// 断言只管"落在哪一臂"，不预设结论。文档说了不算，本卡 §1 的兼容面读数也不算——
// 那一批是用 `x-amz-*` 头名签的，这里全部换成 `x-obs-*` 重跑。

///|
fn live_env() -> (String, String, String, String)? {
  let names : Array[String] = ["OBS_AK", "OBS_SK", "OBS_BUCKET", "OBS_REGION"]
  let missing : Array[String] = []
  for name in names {
    if @env.get_env_var(name).unwrap_or("").is_empty() {
      missing.push(name)
    }
  }
  if missing.length() > 0 {
    println("live env missing: " + missing.join(", "))
    None
  } else {
    Some(
      (
        @env.get_env_var("OBS_AK").unwrap_or(""),
        @env.get_env_var("OBS_SK").unwrap_or(""),
        @env.get_env_var("OBS_BUCKET").unwrap_or(""),
        @env.get_env_var("OBS_REGION").unwrap_or(""),
      ),
    )
  }
}

///|
/// 跳过不是通过：这一轮没量到什么，逐条说清楚。
fn live_skip() -> Unit {
  println("SKIP live OBS checks: OBS_* not supplied")
  println(
    "SKIP IS NOT A PASS: 本轮没有对 OBS **原生协议面**做出任何证明——" +
    "没量 list-type=2 收不收、没量分片最小段尺寸校不校、没量 x-obs-acl 的取值面与 " +
    "GET ?acl 回体里 grant 的拼法，也没跑预签名与对象族的真端点往返。",
  )
}

///|
fn live_build(
  ak : String,
  sk : String,
  region : String,
) -> @obs.Client raise @error.ObsError {
  let credentials = @auth.Credentials::new(ak, sk)
  let config = @config.Config::from_region(region, credentials)
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  @obs.Client::new(config, transport)
}

///|
/// 本轮运行号：`OBS_RUN_TAG` 优先（hub 门禁脚本按 `RUNTAG=` 导出的那一个），没给就退回
/// **进程内缓存**的毫秒号。缓存是必须的——每一档各自现取毫秒会把"本轮前缀"算成七个互不相同
/// 的串，那样开头清扫永远扫不到上一轮留下的残留（守卫会绿着空转）。
/// 退回首款时不同进程各算一套 ⇒ 开头清扫只保证"同一轮次号内不漏"；要把上一轮中途死掉的
/// 残留扫干净，就得把 `OBS_RUN_TAG` 钉成上一轮那一个（门禁脚本已经这么导了）。
let live_tag_cache : Array[String] = []

///|
fn live_run_tag() -> String {
  if !live_tag_cache.is_empty() {
    live_tag_cache[0]
  } else {
    let given = @env.get_env_var("OBS_RUN_TAG").unwrap_or("")
    let tag = if given.is_empty() {
      "millis" + @auth.now_millis().to_string()
    } else {
      given
    }
    live_tag_cache.push(tag)
    tag
  }
}

///|
/// 本轮前缀：`moonfs-live-<YYYYMMDD>/obs-native-<运行号>-`。
/// 运行号进前缀 ⇒ 开头清扫只扫自己这一轮，不会把同一只桶上别的轮次（别的腿）删掉。
fn live_root() -> String raise @error.ObsError {
  let stamp = @auth.date_stamp(@auth.now_millis())
  "moonfs-live-" + stamp + "/obs-native-" + live_run_tag() + "-"
}

///|
fn live_bytes(text : String) -> Bytes {
  @utf8.encode(text.view())
}

///|
fn live_text(data : Bytes) -> String {
  @utf8.decode_lossy(data.exact_view())
}

///|
fn live_or_blank(value : String?) -> String {
  match value {
    Some(v) => v
    None => ""
  }
}

///|
/// 服务端错误码读数。`HEAD` 那一族没有正文，读不出码时退回状态码——
/// 判"对象不存在"要看 `status` 而不能只看 `code`。
fn live_code(err : @error.ObsError) -> String {
  match err {
    @error.ObsError::Service(details) =>
      if details.code.is_empty() {
        "status:" + details.status.to_string()
      } else {
        details.code + "(status:" + details.status.to_string() + ")"
      }
    @error.ObsError::Network(detail) => "network:" + detail
    other => other.text()
  }
}

///|
/// 只报长度，不报值：AK／SK 一旦进日志就等于多一份可用的凭据。
fn live_env_note(environment : (String, String, String, String)) -> String {
  "ak长度=" +
  environment.0.length().to_string() +
  " sk长度=" +
  environment.1.length().to_string() +
  " 桶名长度=" +
  environment.2.length().to_string() +
  " 区域=" +
  environment.3
}

///|
/// 回体与键名里可能带桶名，打印前一律换成 `<桶>`。
/// （这一档的**所有** println 都走它，免得某一条读数把测试桶名抄进公开日志。）
fn live_safe(text : String, bucket : String) -> String {
  if bucket.is_empty() {
    text
  } else {
    text.replace(old=bucket, new="<桶>")
  }
}

///|
/// 截断到给定宽度（回体只用来认形状，不整份进日志）。
fn live_trim(text : String, limit : Int32) -> String {
  if text.length() <= limit {
    text
  } else {
    text[0:limit].to_owned() + "…"
  }
}

///|
fn live_pairs(pairs : Array[(String, String)]) -> String {
  let parts : Array[String] = []
  for pair in pairs {
    parts.push(pair.0 + "=" + pair.1)
  }
  parts.join(" ")
}

///|
fn live_has_pair(
  pairs : Array[(String, String)],
  name : String,
  value : String,
) -> Bool {
  let mut found = false
  for pair in pairs {
    if pair.0 == name && pair.1 == value {
      found = true
    }
  }
  found
}

///|
/// 测试侧自带的一份隐去（黑盒档读不到包里的私有 `redact_query`）。
/// 这一档测的正是预签名 URL，网络抖一下就把一条限时授权抄进日志，所以测试件也要隐。
fn live_redact(text : String) -> String {
  match text.find("?") {
    None => text
    Some(at) => text[0:at].to_owned() + "?<redacted>"
  }
}

///|
fn live_transport_text(err : @transport.TransportError) -> String {
  match err {
    @transport.TransportError::Network(detail) =>
      "network: " + live_redact(detail)
    @transport.TransportError::Timeout => "timeout"
    @transport.TransportError::InvalidRequest(detail) =>
      "invalid-request: " + live_redact(detail)
    @transport.TransportError::InvalidResponse(detail) =>
      "invalid-response: " + live_redact(detail)
  }
}

///|
async fn live_drain(
  body : &@transport.ResponseBody,
) -> Bytes raise @transport.TransportError {
  let merged : Array[Byte] = []
  let mut reading = true
  while reading {
    let chunk = body.read(65536)
    match chunk {
      Some(data) => merged.append(data.to_array())
      None => reading = false
    }
  }
  Bytes::from_array(merged)
}

///|
/// 不带任何凭据打开一条 URL：预签名那一档与"公有读真生效"那一档的验证姿势。
async fn live_open_url(
  url : String,
  verb~ : String = "GET",
  headers~ : Array[(String, String)] = [],
  payload~ : Bytes = @utf8.encode("".view()),
) -> (Int32, String) {
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let wire : Array[@transport.Header] = []
  for pair in headers {
    wire.push(@transport.Header::{ name: pair.0, value: pair.1, })
  }
  let http_method : @transport.Method = match verb {
    "PUT" => @transport.Method::Put
    _ => @transport.Method::Get
  }
  let body : @transport.RequestBody = if payload.length() == 0 {
    @transport.RequestBody::Empty
  } else {
    @transport.RequestBody::Bytes(payload)
  }
  let response = transport.send(@transport.Request::{
    http_method,
    url,
    headers: wire,
    body,
  }) catch {
    err => return (0, "transport: " + live_transport_text(err))
  }
  let status = response.status
  let raw = live_drain(response.body) catch {
    err => {
      response.body.close()
      return (status, "read: " + live_transport_text(err))
    }
  }
  response.body.close()
  (status, live_text(raw))
}

///|
/// 匿名打开一条 URL，**只对传输层失败**重试（status 为 0 就是根本没拿到应答）。
/// 状态码本身不对不归这条管——那是读数，必须原样交出去断言。
/// 公网抖动与传输层 30 秒界是这一族测试的已知现象，重试是对的，放宽断言是错的。
async fn live_open_retry(
  url : String,
  verb~ : String = "GET",
  headers~ : Array[(String, String)] = [],
  payload~ : Bytes = @utf8.encode("".view()),
) -> (Int32, String) {
  let mut last : (Int32, String) = (0, "尚未尝试")
  let mut attempt = 0
  while attempt < 4 && last.0 == 0 {
    last = live_open_url(url, verb~, headers~, payload~)
    if last.0 == 0 {
      println(
        "传输层没拿到应答，重试第 " +
        (attempt + 1).to_string() +
        " 次: " +
        live_trim(last.1, 120),
      )
      @async.sleep(2000)
    }
    attempt = attempt + 1
  }
  last
}

///|
/// 发一发探针，把"传输层没拿到应答"折成 `(None, 文案)`——
/// 这一档不 raise，重试循环才写得出来（`expr catch` 两臂必须同型）。
async fn probe_send_once(
  transport : &@transport.Transport,
  http_method : @transport.Method,
  url : String,
  wire : Array[@transport.Header],
  body : @transport.RequestBody,
) -> (@transport.Response?, String) noraise {
  let response = transport.send(@transport.Request::{
    http_method,
    url,
    headers: wire,
    body,
  }) catch {
    err => return (None, live_transport_text(err))
  }
  (Some(response), "")
}

///|
/// **手签一条公开面上没有的请求**，取真端点的读数。
/// 这几档（`list-type=2`、path 风格、错区域）的形状不配进 SDK 的公开面，
/// 但它们必须由原生头名（`x-obs-*`）签出来量——用兼容面的读数代替就是本末倒置。
/// 返回 `(状态码, 回体, SignedHeaders)`；传输层失败直接 raise，让调用侧的红有意义。
async fn live_probe(
  client : @obs.Client,
  host : String,
  canonical_uri : String,
  wire_url : String,
  verb : String,
  query : Array[(String, String)],
  extra_headers~ : Array[(String, String)] = [],
  payload~ : Bytes = @utf8.encode("".view()),
  prefix~ : @auth.HeaderPrefix = @obs.signed_prefix,
) -> (Int32, String, String) raise @error.ObsError {
  let config = client.config_of()
  let millis = @auth.now_millis()
  let timestamp = @auth.iso8601_basic(millis)
  let required = @auth.required_headers(timestamp, prefix~)
  let signature = config
    .credentials()
    .sign_at(
      config.region_of(),
      millis,
      @auth.RequestToSign::{
        verb,
        canonical_uri,
        query,
        headers: [("host", host)] + extra_headers,
        payload_hash: @auth.unsigned_payload,
      },
      header_prefix=prefix,
    )
  let wire_query = @auth.canonical_query_string(query)
  let url = if wire_query.is_empty() {
    wire_url
  } else {
    wire_url + "?" + wire_query
  }
  let wire : Array[@transport.Header] = []
  for pair in required + extra_headers {
    wire.push(@transport.Header::{ name: pair.0, value: pair.1, })
  }
  wire.push(@transport.Header::{
    name: "authorization",
    value: signature.authorization,
  })
  let http_method : @transport.Method = match verb {
    "GET" => @transport.Method::Get
    "PUT" => @transport.Method::Put
    "POST" => @transport.Method::Post
    "DELETE" => @transport.Method::Delete
    _ => raise @error.BadParam("probe verb not supported: " + verb)
  }
  let body : @transport.RequestBody = if payload.length() == 0 {
    @transport.RequestBody::Empty
  } else {
    @transport.RequestBody::Bytes(payload)
  }
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  // 传输层抖动（含 30 秒界）重试到拿到应答为止；拿不到就 raise，让那一档红得看得见。
  let mut sent : @transport.Response? = None
  let mut failure = ""
  let mut attempt = 0
  while attempt < 4 && sent is None {
    let outcome = probe_send_once(transport, http_method, url, wire, body)
    sent = outcome.0
    failure = outcome.1
    if sent is None {
      println(
        "探针传输层没拿到应答，重试第 " +
        (attempt + 1).to_string() +
        " 次: " +
        live_trim(failure, 120),
      )
      @async.sleep(2000)
    }
    attempt = attempt + 1
  }
  let response = match sent {
    None => raise @error.Network("探针重发 4 次仍无应答: " + failure)
    Some(one) => one
  }
  let status = response.status
  let raw = live_drain(response.body) catch {
    err => raise @error.Network(live_transport_text(err))
  }
  response.body.close()
  (status, live_text(raw), signature.signed_headers)
}

///|
/// 是不是**只有传输层死亡**（没拿到应答、30 秒界、连接半路断）。协议层的红——状态码与服务端码
/// 不对——一律落在这条之外：本线的纪律是"传输层死亡可以重发，协议层读数一次都不重试"，
/// 判据本身不许因为链路抖过就放宽（放宽就是把"端点没答"读成"端点认了"）。
fn live_is_transport_death(err : @error.ObsError) -> Bool {
  match err {
    @error.ObsError::Network(_) => true
    _ => false
  }
}

///|
/// 复列一个前缀下的**全部**键。用公开面 `list_objects`（V1）来扫，不另开一条查询路径。
/// 分页：原生 V1 不带 delimiter 时**不回 `<NextMarker>`**（10-19 实测形状），所以续页符
/// 退回"本页最后一个键"——只认 NextMarker 的话，第 1001 个之后的残留会静悄悄地扫不到。
async fn live_keys_under(
  client : @obs.Client,
  bucket : String,
  prefix : String,
) -> Array[String] raise @error.ObsError {
  let keys : Array[String] = []
  let mut marker = ""
  let mut page = 0
  let mut done = false
  while !done && page < 20 {
    page = page + 1
    let listing = client.list_objects(bucket, prefix~, marker~, max_keys=1000)
    let mut last = ""
    for item in listing.objects {
      keys.push(item.key)
      last = item.key
    }
    let next = live_or_blank(listing.next_marker)
    let cursor = if !next.is_empty() { next } else { last }
    done = !listing.is_truncated || cursor.is_empty()
    marker = cursor
  }
  keys
}

///|
/// 复列一个前缀的读数串（只读，不删）：`count=<n> keys=<前 200 字符>`。
async fn live_sweep(
  client : @obs.Client,
  bucket : String,
  prefix : String,
) -> String {
  let keys = live_keys_under(client, bucket, prefix) catch {
    err => return "error:" + live_code(err)
  }
  "count=" +
  keys.length().to_string() +
  " keys=" +
  live_trim(live_safe(keys.join(","), bucket), 200)
}

// 重发层数（10-21 收口）：删件／列页／清扫这一族的每一发都走 SDK 公开面，而
// "响应头未到达 ⇒ 幂等档重发一次"已经收进 `obs/request.mbt`。原先这里另有两处叠在 SDK 之上的
// 壳（`live_delete_retry` 的三趟、`live_clean` 的三趟）已撤掉——两层重试数不出层数，
// 红的时候也分不清是哪一层兜住的。仍保留重发循环的只有**不经 SDK 的那几发**：
// `live_open_retry`（匿名/预签名 GET，裸 transport.send）与 `live_probe`（手签探针），
// 那些压根没过 SDK 请求层，SDK 那一档管不着。
// 下面两个件都只跑一趟。

///|
/// 一趟清扫：列尽前缀下的键 → 逐个删（删件不在这层重发，见上面那段）→ 复列剩余。
/// raise 只在"列不出来"时发生（协议层的拒由调用侧分档，不在这儿吞掉）。
async fn live_clean_once(
  client : @obs.Client,
  bucket : String,
  prefix : String,
) -> Int64 raise @error.ObsError {
  let keys = live_keys_under(client, bucket, prefix)
  println(
    "清扫 " +
    live_trim(live_safe(prefix, bucket), 120) +
    " 找到 " +
    keys.length().to_string() +
    " 个: " +
    live_trim(live_safe(keys.join(","), bucket), 200),
  )
  for key in keys {
    println(
      "  删 " +
      live_trim(live_safe(key, bucket), 120) +
      " -> " +
      live_delete(client, bucket, key),
    )
  }
  live_keys_under(client, bucket, prefix).length().to_int64()
}

///|
/// 清扫一个前缀并返回剩余个数：`>=0` 是复列到的实数，`-1` 是**这一趟**在传输层没拿到应答
/// （SDK 那层已按幂等档重发过一次，还是没拿到就是真没拿到），`-2` 是被服务端拒了
/// （协议层红，按纪律**不重试**）。两个负数都不许被读成"扫干净了"。
async fn live_clean(
  client : @obs.Client,
  bucket : String,
  prefix : String,
) -> Int64 {
  live_clean_once(client, bucket, prefix) catch {
    err =>
      if live_is_transport_death(err) {
        println(
          "清扫这一趟在传输层没拿到应答（SDK 层已重发过一次）: " +
          live_code(err),
        )
        -1
      } else {
        println(
          "清扫被服务端拒了，按本线纪律**不重试**: " +
          live_code(err),
        )
        -2
      }
  }
}

///|
/// 开头清扫：无条件先把**本档自己那条**前缀扫一遍（上一轮这一档中途红掉留下的残留就在这一趟
/// 被删掉），并把"剩余必须为 0"当成这一档的入场条件——扫不干净就别往下写。
async fn live_open_clean(
  client : @obs.Client,
  bucket : String,
  prefix : String,
  label : String,
) -> Unit {
  let opening = live_clean(client, bucket, prefix)
  println(
    label +
    " 开头清扫 " +
    live_trim(live_safe(prefix, bucket), 120) +
    " -> 剩余" +
    opening.to_string() +
    " 个",
  )
  if opening < 0 {
    fail(
      label +
      " 开头清扫没跑成（读数 " +
      opening.to_string() +
      "）：残留到底在不在没人证明过",
    )
  }
  assert_eq(opening, 0)
}

///|
/// 结尾清扫 + 交判据。**清扫排在断言之前**：测量段中途红（`fail`／`assert_*` 抛出来）时
/// 这一段仍然跑得到，于是"红一次"不再等于"往桶里漏东西"；红本身一条不放宽，
/// 测量阶段的读数原样再抛一次。
async fn live_close_clean(
  client : @obs.Client,
  bucket : String,
  prefix : String,
  label : String,
  outcome : String,
) -> Unit {
  let residue = live_clean(client, bucket, prefix)
  println(
    label +
    " 结尾清扫 " +
    live_trim(live_safe(prefix, bucket), 120) +
    " -> 剩余" +
    residue.to_string() +
    " 个",
  )
  if outcome != "no-error" {
    if residue != 0 {
      println(
        label +
        " 除了测量阶段的红，结尾清扫也没归零（剩余 " +
        residue.to_string() +
        " 个）",
      )
    }
    fail(outcome)
  }
  if residue < 0 {
    fail(
      label +
      " 结尾清扫没跑成（读数 " +
      residue.to_string() +
      "）：这一档到底漏没漏没人证明过",
    )
  }
  assert_eq(residue, 0)
}

///|
/// `stat` 的读数串：成功报大小，失败报状态码／服务端码。
/// （MoonBit 的 `expr catch` 两臂必须同型，所以分叉放在这种返回 String 的小函数里。）
async fn live_stat_note(
  client : @obs.Client,
  bucket : String,
  key : String,
) -> String {
  let stat = client.stat_object(bucket, key) catch {
    err => return live_code(err)
  }
  "ok:" + stat.size.to_string()
}

///|
async fn live_parts_note(
  client : @obs.Client,
  bucket : String,
  key : String,
  upload_id : String,
) -> String {
  let page = client.list_parts(bucket, key, upload_id) catch {
    err => return live_code(err)
  }
  "ok:" + page.parts.length().to_string()
}

///|
async fn live_list_note(client : @obs.Client, bucket : String) -> String {
  let listing = client.list_objects(bucket, max_keys=1) catch {
    err => return live_code(err)
  }
  "ok:" + listing.objects.length().to_string()
}

///|
/// 删一个键的读数串（成功报 `ok`，失败报服务端码）。
/// `noraise`：这一发把错误折成读数而不是抛出去，清扫那条链（`live_clean_once` 是 typed raise）
/// 才调得动它——不注的话 E4118 会把"读数折成串"这件小事变成签名层的事。
async fn live_delete(
  client : @obs.Client,
  bucket : String,
  key : String,
) -> String noraise {
  client.delete_object(bucket, key) catch {
    err => return live_code(err)
  }
  "ok"
}

///|
/// ACL 写的读数：成功报 `ok`，被拒报服务端码。
/// 三档里"能不能签得动 `x-obs-acl`"看的是有没有 `SignatureDoesNotMatch`，
/// 而"服务端让不让这么授权"看的是别的码——两件事分开记。
async fn live_put_acl(
  client : @obs.Client,
  bucket : String,
  key : String,
  acl : String,
) -> String {
  client.put_object_acl(bucket, key, acl) catch {
    err => return live_code(err)
  }
  "ok"
}

///|
/// 一条分片的读数：`状态|码`。
async fn live_upload_part(
  client : @obs.Client,
  bucket : String,
  key : String,
  upload_id : String,
  number : Int32,
  data : Bytes,
) -> (String, String) {
  let etag = client.upload_part(bucket, key, upload_id, number, data) catch {
    err => return ("error:" + live_code(err), "")
  }
  ("ok", etag)
}

///|
/// 完成件的读数：`ok|<etag长度>` 或 `error:<码>`。
async fn live_complete(
  client : @obs.Client,
  bucket : String,
  key : String,
  upload_id : String,
  parts : Array[(Int32, String)],
) -> String {
  let etag = client.complete_multipart_upload(bucket, key, upload_id, parts) catch {
    err => return "error:" + live_code(err)
  }
  "ok:etag长度=" + etag.length().to_string()
}

///|
/// 造一段可辨识的分片正文：每片的首字节就是片号，串不起来就一眼看得出接错序。
fn live_part(number : Int32, size : Int32) -> Bytes {
  let mark : Char = if number == 1 { 'a' } else { 'b' }
  let chars : Array[Char] = []
  for _ in 0..<size {
    chars.push(mark)
  }
  live_bytes(String::from_array(chars))
}

///|
async test "真桶·对象族：写→查→读→范围读→复制→删（原生头名前缀与元数据回显）" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      println(
        "环境读数（只有长度与区域）: " + live_env_note(environment),
      )
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "obj-"
      live_open_clean(client, bucket, prefix, "对象族")
      let outcome = try {
        live_object_measure(client, bucket, root)
        "no-error"
      } catch {
        err => "对象族 测量阶段红: " + err.to_string()
      }
      live_close_clean(client, bucket, prefix, "对象族", outcome)
    }
  }
}

///|
/// 对象族的测量段：写完就地读、读尽就地删，判据落哪一条都从 `fail` 抛给调用侧（调用侧
/// 先扫尾再把红交出去，所以这一段的**每一个**对象都落在 `obj-` 这条子前缀下——中文键那条
/// 以前叫 `对象族-中文 键.txt`，不在 `obj-` 里，中途红掉时结尾清扫扫不到它，2026-10-19 收口）。
async fn live_object_measure(
  client : @obs.Client,
  bucket : String,
  root : String,
) -> Unit {
  let key = root + "obj-source.txt"
  let payload = "moon-obs 原生面对象族读数\nsecond line"
  let written = live_bytes(payload)
  let put = client.put_object(
    bucket,
    key,
    written,
    content_type="text/plain; charset=utf-8",
    metadata=[("tool", "moon-obs")],
  ) catch {
    err => fail("put_object: " + live_code(err))
  }
  println("put etag长度=" + put.etag.length().to_string())
  assert_true(put.etag.length() >= 32)

  let stat = client.stat_object(bucket, key) catch {
    err => fail("stat_object: " + live_code(err))
  }
  println(
    "stat size=" +
    stat.size.to_string() +
    " ctype=" +
    live_or_blank(stat.content_type) +
    " meta=" +
    live_pairs(stat.metadata) +
    " last-modified有=" +
    (stat.last_modified is Some(_)).to_string(),
  )
  // 比的是**字节数**不是字符串长度：那一行中文差 3 个字节，比错就会把
  // "内容被截断了"读成"大小一致"。
  assert_eq(stat.size, written.length().to_int64())
  if !live_has_pair(stat.metadata, "tool", "moon-obs") {
    fail("x-obs-meta-* 没回显出来: " + live_pairs(stat.metadata))
  }

  let got = client.get_object(bucket, key) catch {
    err => fail("get_object: " + live_code(err))
  }
  assert_eq(live_text(got.body), payload)
  assert_eq(got.content_length, written.length().to_int64())

  let ranged = client.get_object(bucket, key, range="bytes=0-3") catch {
    err => fail("范围读: " + live_code(err))
  }
  println(
    "范围读 bytes=" +
    ranged.body.length().to_string() +
    " content-range=" +
    live_or_blank(ranged.content_range),
  )
  assert_eq(ranged.body.length(), 4)
  assert_true(ranged.content_range is Some(_))

  let target = root + "obj-copy-target.txt"
  let copy = client.copy_object(bucket, key, bucket, target) catch {
    err => fail("copy_object: " + live_code(err))
  }
  println(
    "copy etag长度=" +
    copy.etag.length().to_string() +
    " 回体元素名=" +
    @obs.xml_element_names(copy.body).join(","),
  )
  assert_true(copy.etag.length() >= 32)
  let copied = client.get_object(bucket, target) catch {
    err => fail("读副本: " + live_code(err))
  }
  assert_eq(live_text(copied.body), payload)

  // 中文键那一格独立验：编码只错一处就会变成"写进去读不出来"
  let cjk = root + "obj-对象族-中文 键.txt"
  let _ = client.put_object(bucket, cjk, live_bytes("cjk")) catch {
    err => fail("写中文键: " + live_code(err))
  }
  let back = client.get_object(bucket, cjk) catch {
    err => fail("读中文键: " + live_code(err))
  }
  assert_eq(live_text(back.body), "cjk")

  println("删源件 -> " + live_delete(client, bucket, key))
  println("删副本 -> " + live_delete(client, bucket, target))
  println("删中文键 -> " + live_delete(client, bucket, cjk))
  let note = live_stat_note(client, bucket, key)
  println("删后再查 stat=" + note)
  assert_eq(note, "status:404")
}

///|
async test "实测①·原生面收不收 list-type=2（V1 与 V2 各签一发对照）" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "lt-"
      live_open_clean(client, bucket, prefix, "实测①")
      let outcome = try {
        live_list_type_measure(client, bucket, prefix)
        "no-error"
      } catch {
        err => "实测① 测量阶段红: " + err.to_string()
      }
      live_close_clean(client, bucket, prefix, "实测①", outcome)
    }
  }
}

///|
/// `list-type=2` 的测量段。放两个键、先拿公开面那条 V1 对照出"这一轮确实看得见两个键"，
/// 再用同一把凭据只加 `list-type=2` 量原生面收不收。
async fn live_list_type_measure(
  client : @obs.Client,
  bucket : String,
  prefix : String,
) -> Unit {
  let key_a = prefix + "a.txt"
  let key_b = prefix + "b.txt"
  let _ = client.put_object(bucket, key_a, live_bytes("aaa")) catch {
    err => fail("放 a: " + live_code(err))
  }
  let _ = client.put_object(bucket, key_b, live_bytes("bbbb")) catch {
    err => fail("放 b: " + live_code(err))
  }

  // 对照臂：公开面那条 V1，先确认"这一轮确实看得见两个键"
  let v1 = client.list_objects(bucket, prefix~, max_keys=10) catch {
    err => fail("V1 列举: " + live_code(err))
  }
  println(
    "V1 对照 行数=" +
    v1.objects.length().to_string() +
    " 回体元素名=" +
    @obs.xml_element_names(v1.body).join(","),
  )
  assert_true(v1.objects.length() >= 2)

  // 实测臂：同一把凭据、同一套 `x-obs-*` 头名，只加 `list-type=2`
  let query : Array[(String, String)] = [
    ("list-type", "2"),
    ("max-keys", "5"),
    ("prefix", prefix),
  ]
  let config = client.config_of()
  let reading = live_probe(
    client,
    config.host_of(bucket),
    config.canonical_uri_of(bucket),
    config.url_of(bucket),
    "GET",
    query,
  ) catch {
    err => fail("探针: " + live_code(err))
  }
  let status = reading.0
  let body = reading.1
  let names = @obs.xml_element_names(body)
  let v2_shape = live_has_name_readout(names, "KeyCount") ||
    live_has_name_readout(names, "NextContinuationToken")
  let v1_shape = live_has_name_readout(names, "Marker")
  let code = @obs.xml_error_code(body)
  println(
    "实测① 原生面 list-type=2: status=" +
    status.to_string() +
    " 码=<" +
    code +
    "> 含KeyCount/NextContinuationToken=" +
    v2_shape.to_string() +
    " 含Marker=" +
    v1_shape.to_string(),
  )
  println(
    "实测① 回体元素名=" +
    live_trim(names.join(","), 400) +
    " SignedHeaders=" +
    reading.2,
  )
  if status == 200 {
    // 收下：要么真换了 V2 形态，要么把参数当不存在仍回 V1——两种都得能从字段名读出来
    let rows = @obs.xml_all(body, "Key")
    println("实测① 回体里 Key 条数=" + rows.length().to_string())
    assert_true(rows.length() >= 2)
    assert_true(v1_shape || v2_shape)
  } else {
    // 拒下：必须给一个服务端码，且不能是签名层错（那说明我们这发签歪了，不是它不收）
    assert_true(status == 400 || status == 403)
    assert_true(!code.is_empty())
    assert_true(code != "SignatureDoesNotMatch")
  }

  println("删 a -> " + live_delete(client, bucket, key_a))
  println("删 b -> " + live_delete(client, bucket, key_b))
}

///|
fn live_has_name_readout(names : Array[String], want : String) -> Bool {
  let mut found = false
  for name in names {
    if name == want {
      found = true
    }
  }
  found
}

///|
/// 实测③：`x-obs-acl` 的取值面 + `GET /key?acl=` 回体里 grant 的拼法。
/// 兼容面的读数是"public-read 生效、回读 2 条 grant 含 AllUsers 读"——
/// 原生面**不许照抄**，逐档重量：写侧认哪些值、匿名读是否真跟着变、回体里
/// `Grantee` 靠什么属性分档、命名空间是哪一版。
async test "实测③·x-obs-acl 取值面与 GET ?acl 回体里 grant 的拼法" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "acl-"
      live_open_clean(client, bucket, prefix, "实测③")
      let outcome = try {
        live_acl_measure(client, bucket, root)
        "no-error"
      } catch {
        err => "实测③ 测量阶段红: " + err.to_string()
      }
      live_close_clean(client, bucket, prefix, "实测③", outcome)
    }
  }
}

///|
/// ACL 取值面的测量段：一个对象上把 private／public-read／其余取值／坏取值各问一遍，
/// 匿名读两问（收下之后必须真能取、改回 private 之后必须真取不到）。
async fn live_acl_measure(
  client : @obs.Client,
  bucket : String,
  root : String,
) -> Unit {
  let key = root + "acl-object.txt"
  let payload = "acl 取值面读数"
  let _ = client.put_object(bucket, key, live_bytes(payload)) catch {
    err => fail("放对象: " + live_code(err))
  }

  // 基线：private 一定能签、一定能读回
  let base = live_put_acl(client, bucket, key, "private")
  println("x-obs-acl=private -> " + base)
  assert_eq(base, "ok")
  let before = client.get_object_acl(bucket, key) catch {
    err => fail("读 acl(private): " + live_code(err))
  }
  println(
    "回体命名空间=" +
    live_or_blank(before.default_ns) +
    " grant条数=" +
    before.grants.length().to_string() +
    " owner长度=" +
    live_or_blank(before.owner_id).length().to_string(),
  )
  let before_names = live_grant_shapes(before.grants)
  println("回体里 grant 的拼法(private): " + before_names)
  println(
    "回体元素名: " +
    live_trim(@obs.xml_element_names(before.body).join(","), 400),
  )
  assert_true(before.grants.length() >= 1)

  // 公有读：写侧认不认 + 匿名读是否真变 + 回体里多出来的那条怎么拼
  let public_note = live_put_acl(client, bucket, key, "public-read")
  println("x-obs-acl=public-read -> " + public_note)
  let config = client.config_of()
  let anon_url = config.url_of(bucket, key~)
  let (anon_status, anon_body) = live_open_retry(anon_url)
  println(
    "匿名 GET(public-read 之后) status=" +
    anon_status.to_string() +
    " 字节=" +
    anon_body.length().to_string(),
  )
  let after = client.get_object_acl(bucket, key) catch {
    err => fail("读 acl(public-read): " + live_code(err))
  }
  let after_names = live_grant_shapes(after.grants)
  println("回体里 grant 的拼法(public-read): " + after_names)
  assert_true(after.grants.length() >= 1)
  if public_note == "ok" {
    // 收下这一档：匿名读必须真的能取，且回体里必须出现"组授权"那条（AllUsers 那一族）
    assert_eq(anon_status, 200)
    assert_true(live_has_group_grant(after.grants))
  } else {
    // 拒下：必须给服务端码，且不能是签名层错；匿名读也该仍是拒
    assert_true(public_note.has_prefix("status:") || public_note.contains("("))
    assert_true(!public_note.contains("SignatureDoesNotMatch"))
    assert_true(anon_status == 403 || anon_status == 404)
  }

  // 取值面逐档量（本家特有的两档也在内）
  let values : Array[String] = [
    "public-read-write", "log-delivery-read", "encrypt-decrypt-read", "bucket-owner-read",
  ]
  let readings : Array[String] = []
  for value in values {
    let note = live_put_acl(client, bucket, key, value)
    readings.push(value + "->" + note)
    if note.contains("SignatureDoesNotMatch") {
      fail("x-obs-acl 这一族签不动: " + value + " " + note)
    }
  }
  println("取值面其余档: " + readings.join(" "))

  // 坏取值：认不认由端点说，但我们必须能从读数里看出它认了还是没认
  let bogus = live_put_acl(client, bucket, key, "moonfs-not-a-canned-acl")
  println("x-obs-acl=<坏取值> -> " + bogus)
  let after_bogus = client.get_object_acl(bucket, key) catch {
    err => fail("读 acl(坏取值之后): " + live_code(err))
  }
  if bogus == "ok" {
    // 收下坏值就是"忽略未知名"：回体不许因此多出一条组授权
    println(
      "坏取值被收下，回体条数=" +
      after_bogus.grants.length().to_string(),
    )
    assert_true(!live_has_group_grant(after_bogus.grants))
  } else {
    assert_true(!bogus.contains("SignatureDoesNotMatch"))
  }

  // 改回 private：公有读必须真的撤回（可逆，与兼容面同读数才算对上）
  let revert = live_put_acl(client, bucket, key, "private")
  println("改回 private -> " + revert)
  assert_eq(revert, "ok")
  let (anon_after, anon_after_body) = live_open_retry(anon_url)
  println(
    "匿名 GET(private 之后) status=" +
    anon_after.to_string() +
    " 文案=" +
    live_trim(anon_after_body, 120),
  )
  assert_true(anon_after == 403 || anon_after == 404)

  println("删对象 -> " + live_delete(client, bucket, key))
}

///|
/// grant 拼法的读数串：`<Grantee 的 xsi:type>/<权限>`，带 URI 的那条把"是不是 all_users"
/// 读成布尔而不是抄整串（协议常量不进日志也无所谓，但形状读数要留着）。
fn live_grant_shapes(grants : Array[@obs.Grant]) -> String {
  let parts : Array[String] = []
  for grant in grants {
    let uri = live_or_blank(grant.grantee_uri)
    let id = live_or_blank(grant.grantee_id)
    let email = live_or_blank(grant.grantee_email)
    let target = if !uri.is_empty() {
      // 这条 URI 是协议常量（公有组那一族的标识），不是凭据也不是内网地址：
      // "grant 到底怎么拼"要的就是这一串，打成布尔就把读数打没了。
      "URI=" + uri
    } else if !id.is_empty() {
      "ID长度=" + id.length().to_string()
    } else if !email.is_empty() {
      "有EmailAddress"
    } else {
      "无ID无URI无邮箱"
    }
    parts.push(
      "<" + grant.grantee_type + ">" + grant.permission + "[" + target + "]",
    )
  }
  parts.join(" ")
}

///|
/// 组授权（AllUsers 那一族）有没有出现：`Grantee` 带 `<URI>` 就算。
fn live_has_group_grant(grants : Array[@obs.Grant]) -> Bool {
  let mut found = false
  for grant in grants {
    if !live_or_blank(grant.grantee_uri).is_empty() {
      found = true
    }
  }
  found
}

///|
/// 实测②：分片族五步 + **原生面校不校验最小段尺寸**。
/// 兼容面的读数是"100KiB 非末片 + 1KiB 末片 ⇒ COMPLETE 200"（不校验），
/// 官方文档另有最小段尺寸的说法 ⇒ 这里单独量，并且把"文档说的下限存不存在"
/// 用一档**低于** 100KB 的非末片问出来。两臂都断：收下就验对象，拒下就验码与"对象不在"。
async test "实测②·分片五步与原生面的最小段尺寸" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "mp-"
      live_open_clean(client, bucket, prefix, "实测②")
      let outcome = try {
        live_multipart_measure(client, bucket, root)
        "no-error"
      } catch {
        err => "实测② 测量阶段红: " + err.to_string()
      }
      live_close_clean(client, bucket, prefix, "实测②", outcome)
    }
  }
}

///|
/// 分片族的测量段：A 档走满五步，B/C/D 三档各问一发最小段尺寸，最后负向问一发"放弃之后再查"。
/// 这一段的中途红由调用侧的结尾清扫兜着（以前的写法是"扫完再判"，D 档那一步排在清扫**之后**，
/// 前三档里任何一条判据红掉都会把 `mp-*` 留在桶里）。
async fn live_multipart_measure(
  client : @obs.Client,
  bucket : String,
  root : String,
) -> Unit {
  // A 档：正常两片（各 256KiB）走满五步
  let key_a = root + "mp-normal.bin"
  let part_size = 256 * 1024
  let id_a = client.create_multipart_upload(
    bucket,
    key_a,
    content_type="application/octet-stream",
  ) catch {
    err => fail("create A: " + live_code(err))
  }
  println("A档 uploadId长度=" + id_a.length().to_string())
  let a1 = live_upload_part(
    client,
    bucket,
    key_a,
    id_a,
    1,
    live_part(1, part_size),
  )
  let a2 = live_upload_part(
    client,
    bucket,
    key_a,
    id_a,
    2,
    live_part(2, part_size),
  )
  println("A档 两片 -> " + a1.0 + " / " + a2.0)
  assert_eq(a1.0, "ok")
  assert_eq(a2.0, "ok")
  let page = client.list_parts(bucket, key_a, id_a) catch {
    err => fail("list_parts A: " + live_code(err))
  }
  println(
    "A档 list_parts 条数=" +
    page.parts.length().to_string() +
    " 首片号=" +
    page.parts[0].part_number.to_string() +
    " 首片大小=" +
    page.parts[0].size.to_string() +
    " 元素名=" +
    @obs.xml_element_names(page.body).join(","),
  )
  assert_eq(page.parts.length(), 2)
  assert_eq(page.parts[0].size, part_size.to_int64())
  let done_a = live_complete(client, bucket, key_a, id_a, [(1, a1.1), (2, a2.1)])
  println("A档 COMPLETE -> " + done_a)
  assert_true(done_a.has_prefix("ok"))
  let stat_a = client.stat_object(bucket, key_a) catch {
    err => fail("合并后 stat: " + live_code(err))
  }
  assert_eq(stat_a.size, (part_size * 2).to_int64())
  println("删 A -> " + live_delete(client, bucket, key_a))

  // B 档：100KiB 非末片 + 1KiB 末片（与兼容面同一形状，问原生面认不认）
  let key_b = root + "mp-100k.bin"
  let b_plan = live_min_size_arm(client, bucket, key_b, 100 * 1024)
  println("实测② B档(非末片100KiB) -> " + b_plan)
  // C 档：50KiB 非末片——**低于文档说的 100KB 下限**，这一档才是"下限存不存在"
  let key_c = root + "mp-50k.bin"
  let c_plan = live_min_size_arm(client, bucket, key_c, 50 * 1024)
  println("实测② C档(非末片50KiB，低于文档下限) -> " + c_plan)
  // D 档：100KiB 差一字节——把下限的**边界值**夹出来（B 档正好是 100KiB）
  let key_e = root + "mp-100k-1.bin"
  let e_plan = live_min_size_arm(client, bucket, key_e, 100 * 1024 - 1)
  println("实测② D档(非末片100KiB-1) -> " + e_plan)

  // 两臂都断得住：要么 COMPLETE 真落地，要么服务端给一个成名的码；5xx／传输错一律红
  for note in [b_plan, c_plan, e_plan] {
    if note.has_prefix("complete-ok") {
      assert_true(!note.has_prefix("complete-ok:stat-missing"))
    } else if note.has_prefix("complete-error") {
      assert_true(!note.contains("SignatureDoesNotMatch"))
    } else {
      fail("读数落在两臂之外: " + note)
    }
  }
  println("删 B -> " + live_delete(client, bucket, key_b))
  println("删 C -> " + live_delete(client, bucket, key_c))
  println("删 D -> " + live_delete(client, bucket, key_e))

  // 负向：放弃之后再查分片必须给一个成名的码，不能"看起来是空列表"
  let key_d = root + "mp-abort.bin"
  let id_d = client.create_multipart_upload(bucket, key_d) catch {
    err => fail("create D: " + live_code(err))
  }
  client.abort_multipart_upload(bucket, key_d, id_d) catch {
    err => fail("abort D: " + live_code(err))
  }
  let d_note = live_parts_note(client, bucket, key_d, id_d)
  println("放弃之后再查 list_parts -> " + d_note)
  assert_true(d_note.has_prefix("ok:") || d_note.contains("Upload"))
  if d_note.has_prefix("ok:") {
    fail("放弃之后不该回空列表: " + d_note)
  }
}

///|
/// 一档最小段尺寸的读数：两片（非末片 `first_size` + 末片 1KiB）→ COMPLETE → stat。
/// 返回一个把**每一步读数都编进串**的结果，供调用侧断两臂与打印。
async fn live_min_size_arm(
  client : @obs.Client,
  bucket : String,
  key : String,
  first_size : Int32,
) -> String {
  let upload_id = client.create_multipart_upload(bucket, key) catch {
    err => return "create-error:" + live_code(err)
  }
  let p1 = client.upload_part(
    bucket,
    key,
    upload_id,
    1,
    live_part(1, first_size),
  ) catch {
    err => {
      let _ = client.abort_multipart_upload(bucket, key, upload_id) catch {
        _ => ()
      }
      return "part1-error:" + live_code(err)
    }
  }
  let p2 = client.upload_part(bucket, key, upload_id, 2, live_part(2, 1024)) catch {
    err => {
      let _ = client.abort_multipart_upload(bucket, key, upload_id) catch {
        _ => ()
      }
      return "part2-error:" + live_code(err)
    }
  }
  let done = client.complete_multipart_upload(bucket, key, upload_id, [
    (1, p1),
    (2, p2),
  ]) catch {
    err => {
      let code = live_code(err)
      let _ = client.abort_multipart_upload(bucket, key, upload_id) catch {
        _ => ()
      }
      return "complete-error:" + code
    }
  }
  let stat = client.stat_object(bucket, key) catch {
    err => return "complete-ok:stat-missing:" + live_code(err)
  }
  let size = stat.size
  "complete-ok:etag长度=" +
  done.length().to_string() +
  " 合并大小=" +
  size.to_string()
}

///|
async test "真桶·预签名：GET 免凭据可取、改签名即拒；PUT 直传真落盘" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "presign-"
      live_open_clean(client, bucket, prefix, "预签名")
      let outcome = try {
        live_presign_measure(client, bucket, root)
        "no-error"
      } catch {
        err => "预签名 测量阶段红: " + err.to_string()
      }
      live_close_clean(client, bucket, prefix, "预签名", outcome)
    }
  }
}

///|
async fn live_presign_measure(
  client : @obs.Client,
  bucket : String,
  root : String,
) -> Unit {
  let key = root + "presign-get.txt"
  let _ = client.put_object(bucket, key, live_bytes("presigned payload")) catch {
    err => fail("put: " + live_code(err))
  }
  let url = client.presigned_get_url(bucket, key, expires_sec=120L) catch {
    err => fail("presigned_get_url: " + live_code(err))
  }
  // URL 里带着签名，日志只打长度：那条 query 本身就是一份限时授权
  println("预签名 GET url长度=" + url.length().to_string())
  let (status, body) = live_open_retry(url)
  println("预签名 GET status=" + status.to_string())
  assert_eq(status, 200)
  assert_eq(body, "presigned payload")

  // 裸读对照：不带签名的同一地址必须被拒，否则上面那发 200 没在验签名
  let anon = live_open_retry(client.config_of().url_of(bucket, key~))
  println(
    "裸读对照 status=" +
    anon.0.to_string() +
    " 文案=" +
    live_trim(anon.1, 120),
  )
  assert_true(anon.0 == 403 || anon.0 == 404)

  // 改一个字符的签名：兼容面的读数是 403 SignatureDoesNotMatch。
  // `live_open_retry` 只重发"传输层没拿到应答"那一臂（status=0），状态码与文案一律原样交出，
  // 所以这一档的判据没被放宽：拿不到 403 就还是红。
  let tampered = live_tamper_tail(url)
  let (bad_status, bad_body) = live_open_retry(tampered)
  let bad_code = @obs.xml_error_code(bad_body)
  println(
    "改签名 status=" +
    bad_status.to_string() +
    " 码=<" +
    bad_code +
    "> SignedHeaders那串仍在query里=" +
    bad_body.contains("SignatureDoesNotMatch").to_string(),
  )
  assert_true(bad_status != 200)
  assert_true(!bad_code.is_empty())

  // PUT 直传
  let put_key = root + "presign-put.txt"
  let put_url = client.presigned_put_url(
    bucket,
    put_key,
    expires_sec=120L,
    content_type="text/plain",
  ) catch {
    err => fail("presigned_put_url: " + live_code(err))
  }
  let (put_status, put_body) = live_open_retry(
    put_url,
    verb="PUT",
    headers=[("content-type", "text/plain")],
    payload=live_bytes("direct upload"),
  )
  println(
    "预签名 PUT status=" +
    put_status.to_string() +
    " 码=<" +
    @obs.xml_error_code(put_body) +
    ">",
  )
  assert_eq(put_status, 200)
  let landed = client.stat_object(bucket, put_key) catch {
    err => fail("直传后 stat: " + live_code(err))
  }
  assert_eq(landed.size, 13L)
  println("删 GET件 -> " + live_delete(client, bucket, key))
  println("删 PUT件 -> " + live_delete(client, bucket, put_key))
}

///|
/// 把签名末位翻一个字符。签名在 query 的最后一段，改它就等于改一条授权。
fn live_tamper_tail(url : String) -> String {
  let chars = url.to_array()
  let last = chars.length() - 1
  // 末位十六进制字符 +1（f 就回 0），只动一位
  let c = chars[last]
  let bumped = (c.to_int() + 1).unsafe_to_char()
  chars[last] = if c == 'f' { '0' } else if c == '0' { '1' } else { bumped }
  String::from_array(chars)
}

///|
/// 负向对照：错密钥必须**拒在签名层**（`SignatureDoesNotMatch`）。
/// 若读到的是 `AccessDenied`／`InvalidAccessKeyId`，说明请求没走到验签，
/// 那上面所有"签名被认"的读数都不成立。
/// 这一档只发一发桶级列举、**不落任何对象**，所以它没有自家前缀可扫（清扫纪律那三档
/// ——开头扫、结尾扫、阳性对照——对它不适用，别为它造一个空转的清扫）。
async test "真桶·负向对照：错密钥必须拒在签名层" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let client = live_build(
        environment.0,
        environment.1 + "zz",
        environment.3,
      ) catch {
        err => fail("setup: " + err.text())
      }
      let reading = live_list_note(client, bucket)
      println("错密钥读数=" + reading)
      assert_true(!reading.has_prefix("ok:"))
      assert_true(reading.contains("SignatureDoesNotMatch"))
    }
  }
}

///|
/// 顺手量的"与兼容面读数不同"那几格（都换成 `x-obs-*` 头名重签）：
/// · path 风格在**原生面**回什么（兼容面：403 VirtualHostDomainRequired 带正文）；
/// · 区域签错在**原生面**回什么（兼容面：404 NoSuchBucket，与"桶不存在"同形不可分辨）。
async test "实测附·path 风格与错区域在原生面的码（与兼容面对照）" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "path-"
      live_open_clean(client, bucket, prefix, "实测附")
      let outcome = try {
        live_shape_measure(client, bucket, root, environment.3)
        "no-error"
      } catch {
        err => "实测附 测量阶段红: " + err.to_string()
      }
      live_close_clean(client, bucket, prefix, "实测附", outcome)
    }
  }
}

///|
/// 手签三发的测量段（path 风格／`x-obs-*` 头名族／只带 `x-obs-acl` 的 ACL 写）+ 区域签错那一发。
async fn live_shape_measure(
  client : @obs.Client,
  bucket : String,
  root : String,
  region : String,
) -> Unit {
  let config = client.config_of()
  let key = root + "path-style.txt"
  let _ = client.put_object(bucket, key, live_bytes("path")) catch {
    err => fail("放对象: " + live_code(err))
  }

  // path 风格：桶名进 URL 路径、也进签名资源路径（参照实现的 path 档形状）
  let path_host = config.host_of("")
  let path_uri = "/" + bucket + "/" + key
  let path_url = config.scheme_of() +
    "://" +
    path_host +
    "/" +
    bucket +
    "/" +
    key
  let path_reading = live_probe(client, path_host, path_uri, path_url, "GET", []) catch {
    err => fail("path 探针: " + live_code(err))
  }
  let path_code = @obs.xml_error_code(path_reading.1)
  println(
    "实测附 path 风格: status=" +
    path_reading.0.to_string() +
    " 码=<" +
    path_code +
    "> 正文长度=" +
    path_reading.1.length().to_string() +
    " SignedHeaders=" +
    path_reading.2,
  )
  assert_true(
    path_reading.0 == 200 ||
    (path_reading.0 == 403 && path_code == "VirtualHostDomainRequired"),
  )
  if path_reading.0 == 200 {
    println(
      "读数与兼容面**不同**：原生面收了 path 风格——config 的拒绝口径要重估",
    )
  }

  // 头名族那一格：把两个必带头换成 `x-obs-*`（本包默认不发这一族），
  // 看端点回什么。参照实现的适配器写着"前缀二选一"，真桶得自己答。
  let obs_family = live_probe(
    client,
    config.host_of(bucket),
    config.canonical_uri_of(bucket),
    config.url_of(bucket),
    "GET",
    [("max-keys", "1")],
    prefix=@auth.HeaderPrefix::Obs,
  ) catch {
    err => fail("x-obs 探针: " + live_code(err))
  }
  let obs_family_code = @obs.xml_error_code(obs_family.1)
  println(
    "实测附 头名族: 用 x-obs-date/x-obs-content-sha256 签 -> status=" +
    obs_family.0.to_string() +
    " 码=<" +
    obs_family_code +
    "> 正文元素名=" +
    @obs.xml_element_names(obs_family.1).join(",") +
    " SignedHeaders=" +
    obs_family.2,
  )
  if obs_family.0 == 200 {
    println(
      "读数：原生端点也认 x-obs-* 那族头名，与本包默认口径不一致",
    )
  } else {
    assert_true(obs_family.0 == 400)
    assert_true(
      obs_family_code == "InvalidArgument" ||
      obs_family_code == "MissingSecurityHeader",
    )
  }

  // 只带 `x-obs-acl`（不带 `x-amz-acl`）的 ACL 写：这一族在本家读不读
  let obs_acl = live_probe(
    client,
    config.host_of(bucket),
    config.canonical_uri_of(bucket, key~),
    config.url_of(bucket, key~),
    "PUT",
    [("acl", "")],
    extra_headers=[("x-obs-acl", "public-read")],
  ) catch {
    err => fail("x-obs-acl 探针: " + live_code(err))
  }
  println(
    "实测附 取值面: 只带 x-obs-acl=public-read 的 PUT ?acl -> status=" +
    obs_acl.0.to_string() +
    " 码=<" +
    @obs.xml_error_code(obs_acl.1) +
    ">",
  )
  assert_true(obs_acl.0 == 200 || obs_acl.0 == 400)

  // 区域签错：签名 scope 用别的区域，端点仍是真桶那一个
  let wrong_region = live_other_region(region)
  let wrong_reading = live_probe_with_region(
    client,
    wrong_region,
    config.host_of(bucket),
    config.canonical_uri_of(bucket),
    config.url_of(bucket),
  ) catch {
    err => fail("错区域探针: " + live_code(err))
  }
  let wrong_code = @obs.xml_error_code(wrong_reading.1)
  println(
    "实测附 区域签错(" +
    wrong_region +
    "): status=" +
    wrong_reading.0.to_string() +
    " 码=<" +
    wrong_code +
    "> 正文元素名=" +
    @obs.xml_element_names(wrong_reading.1).join(","),
  )
  // 两臂都断得住：要么这一发被拒（给一个成名的码），要么**根本不看 scope 里的区域**。
  // 后者是真桶读数：把 scope 的区域签成别处照样 200 列出对象 ⇒ 兼容面那条
  // "区域填错回 404 NoSuchBucket"量的不是这一格（那一条量的是打错**主机**）。
  if wrong_reading.0 == 200 {
    println(
      "读数：原生端点不比对 scope 里的区域（签错区域仍回 200）",
    )
    assert_true(@obs.xml_element_names(wrong_reading.1).length() > 0)
  } else {
    assert_true(
      wrong_reading.0 == 400 || wrong_reading.0 == 403 || wrong_reading.0 == 404,
    )
    assert_true(!wrong_code.is_empty())
  }

  println("删对象 -> " + live_delete(client, bucket, key))
}

///|
/// 换一个**不是本桶所在区域**的区域串用来签（不猜桶在哪，只把它签歪）。
fn live_other_region(region : String) -> String {
  if region.has_suffix("1") {
    let head = region[0:region.length() - 1].to_owned()
    head + "9"
  } else {
    region + "9"
  }
}

///|
/// 与 [live_probe] 同一条链，只差签名 scope 里的区域（装配层那条不暴露这个口子）。
async fn live_probe_with_region(
  client : @obs.Client,
  region : String,
  host : String,
  canonical_uri : String,
  wire_url : String,
) -> (Int32, String, String) raise @error.ObsError {
  let config = client.config_of()
  let millis = @auth.now_millis()
  let timestamp = @auth.iso8601_basic(millis)
  let required = @auth.required_headers(timestamp, prefix=@obs.signed_prefix)
  let signature = config
    .credentials()
    .sign_at(
      region,
      millis,
      @auth.RequestToSign::{
        verb: "GET",
        canonical_uri,
        query: [],
        headers: [("host", host)],
        payload_hash: @auth.unsigned_payload,
      },
      header_prefix=@obs.signed_prefix,
    )
  let transport : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let wire : Array[@transport.Header] = []
  for pair in required {
    wire.push(@transport.Header::{ name: pair.0, value: pair.1, })
  }
  wire.push(@transport.Header::{
    name: "authorization",
    value: signature.authorization,
  })
  // 与 [live_probe] 同一条重试口径：**只重发传输层死亡**（含 30 秒界那一臂），状态码与服务端码
  // 一律原样交出去。判据一个字不动——把"链路抖一下"和"端点拒了这一发"分开，才算在验后者。
  let mut sent : @transport.Response? = None
  let mut failure = ""
  let mut attempt = 0
  while attempt < 4 && sent is None {
    let outcome = probe_send_once(
      transport,
      @transport.Method::Get,
      wire_url,
      wire,
      @transport.RequestBody::Empty,
    )
    sent = outcome.0
    failure = outcome.1
    if sent is None {
      println(
        "错区域探针传输层没拿到应答，重试第 " +
        (attempt + 1).to_string() +
        " 次: " +
        live_trim(failure, 120),
      )
      @async.sleep(2000)
    }
    attempt = attempt + 1
  }
  let response = match sent {
    None =>
      raise @error.Network(
        "错区域探针重发 4 次仍无应答: " + failure,
      )
    Some(one) => one
  }
  let status = response.status
  let raw = live_drain(response.body) catch {
    err => raise @error.Network(live_transport_text(err))
  }
  response.body.close()
  (status, live_text(raw), signature.signed_headers)
}

///|
/// 收尾：本轮自家前缀（`moonfs-live-<日期>/obs-native-<运行号>-`）复列，期望 0 残留。
/// 每一档开头扫一次、结尾再扫一次（且**清扫排在断言之前**，中途红也把对象删干净），
/// 这一条是"有没有漏删"的复验，不是"删了就等于没写"的自证——读到非 0 就红，并把键名打出来。
/// 整条腿（`obs-native-` 全轮次）的残留**只报不判**：开头清扫按轮次号隔离，别的轮次正在写的
/// 东西不该由本轮删掉（同一只桶上还有 `moon-s3` 的 OBS 兼容腿与本腿别的轮次），
/// 那种残留由"同一个轮次号再跑一次"或仓外的复列脚本收口，读数打在这里就是给操作者的凭据。
async test "收尾·本轮自家前缀复列必须归零" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let run_root = live_root() catch { err => fail("root: " + err.text()) }
      let millis = @auth.now_millis()
      let stamp = @auth.date_stamp(millis) catch {
        err => fail("stamp: " + err.text())
      }
      let leg_root = "moonfs-live-" + stamp + "/obs-native-"
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      // 同一批 async 用例是**并发**跑的：这条会在别的档还在写的时候就被叫到，
      // 一次读数会把"还没收口"读成"漏删"。所以要复列到有键为止还是等到收口为止——
      // 上限 20 次、每次间隔 3 秒，超上限仍非 0 就红，并把最后一次的键名打出来。
      let readings : Array[String] = []
      let mut settled = false
      let mut attempt = 0
      while attempt < 20 && !settled {
        let reading = live_sweep(client, bucket, run_root)
        readings.push(reading)
        if reading.has_prefix("count=0") {
          settled = true
        } else {
          @async.sleep(3000)
        }
        attempt = attempt + 1
      }
      let last = readings[readings.length() - 1]
      println(
        "本轮前缀(" +
        run_root +
        ")复列: 共" +
        readings.length().to_string() +
        " 轮 -> " +
        last,
      )
      let foreign = live_sweep(client, bucket, leg_root)
      println(
        "整条腿(" +
        leg_root +
        ")复列（只报不判，非本轮的残留归『再跑同一轮次号』或仓外脚本收）: " +
        foreign,
      )
      assert_true(last.has_prefix("count=0"))
    }
  }
}

///|
/// 阳性对照：这一条才是"开头清扫不是空转"的证明。
/// 先放一个对象**故意不删**（那正是"上一档中途红掉留下的残留"的形状），再让每一档开头跑的那一条
/// `live_open_clean` 跑它，然后两路断它确实没了：复列查不到 + `HEAD` 给 404。
/// 没有这一条，"开头清扫"完全可能是一行永远绿着的假守卫（扫的前缀压根盖不住残留的键）。
async test "真桶·阳性对照：开头清扫真会删掉故意留下的残留" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "orphan-"
      // ① 入场清扫（与每一档同姿势），先把自家前缀清成 0
      live_open_clean(client, bucket, prefix, "阳性对照")
      // ② 故意留一个残留：写进去、**不删**、也不做任何收尾
      let orphan = prefix + "orphan-left-behind.txt"
      let _ = client.put_object(
        bucket,
        orphan,
        live_bytes("故意留下的残留"),
      ) catch {
        err => fail("放残留: " + live_code(err))
      }
      let planted = live_sweep(client, bucket, prefix)
      println("阳性对照 故意留下残留之后复列: " + planted)
      assert_true(planted.has_prefix("count=1"))
      let seen = live_stat_note(client, bucket, orphan)
      println("阳性对照 残留还在时 stat=" + seen)
      assert_true(seen.has_prefix("ok:"))
      // ③ 让"下一档的开头清扫"跑它——调的就是每档开头那一条，不另开一条路径
      live_open_clean(client, bucket, prefix, "阳性对照·下一档")
      // ④ 复列查不到，且不是"列不出来"：HEAD 那一发必须真给 404
      let after = live_sweep(client, bucket, prefix)
      println("阳性对照 开头清扫之后复列: " + after)
      assert_true(after.has_prefix("count=0"))
      let gone = live_stat_note(client, bucket, orphan)
      println("阳性对照 开头清扫之后再查 stat=" + gone)
      assert_eq(gone, "status:404")
    }
  }
}
