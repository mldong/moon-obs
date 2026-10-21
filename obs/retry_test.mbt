///|
// 重发档的行为档（黑盒＋桩传输，**不发网络**）。三条证据里"发出去几趟"这一格在这里数：
// 桩件自己记 `sends`，SDK 层重没重发一目了然，不必靠日志文本反推。
// 判定层（资格表与两条日志原文）在 `retry_wbtest.mbt`；真端点档在 `retry_live_test.mbt`。
//
// 黑盒档拿不到包内的 `resend_policy`，所以这里判的是**行为**：给定"响应头没到达"，
// 幂等档总共发两趟、非幂等档总共发一趟、拿到状态码的档不追加第二趟。

///|
/// 桩响应体：第一次 `read` 给全部正文，之后 EOF；`close` 之后再 `read` 必报错（端口那条红线）。
struct StubBody {
  mut sent : Bool
  mut closed : Bool
  answer : Bytes
}

///|
impl @transport.ResponseBody for StubBody with fn read(self, max_len) {
  let _ = max_len
  if self.closed {
    raise @transport.TransportError::InvalidResponse("stub body is closed")
  }
  if self.sent {
    None
  } else {
    self.sent = true
    Some(self.answer)
  }
}

///|
impl @transport.ResponseBody for StubBody with fn close(self) {
  self.closed = true
}

///|
/// 桩传输。`die_first` ＝**前 N 发**在传输层死亡（应答根本还没开始）；
/// `sends` 与 `lines` 是判据的读数口：重没重发、重发的是不是同一发，都在这里数得出来。
struct StubTransport {
  mut sends : Int32
  lines : Array[String]
  bodies : Array[String]
  die_first : Int32
  status : Int32
  headers : Array[@transport.Header]
  answer : Bytes
}

///|
impl @transport.Transport for StubTransport with fn send(self, request) {
  self.sends = self.sends + 1
  self.lines.push(stub_verb_name(request.http_method) + " " + request.url)
  self.bodies.push(stub_body_kind(request.body))
  if self.sends <= self.die_first {
    raise @transport.TransportError::Network(
      "stub: died before any response header",
    )
  }
  let body : &@transport.ResponseBody = StubBody::{
    sent: false,
    closed: false,
    answer: self.answer,
  }
  { status: self.status, headers: self.headers, body, }
}

///|
/// 这一发带的是哪种身体。重发档对 `Stream` 是**一律不重发**的那道闸门，而本 SDK 的公开面
/// 只交 `Empty` 与 `Bytes`（`put_object`／`upload_part` 都收 `Bytes`）⇒ 那道闸门在公开面上
/// 不可达。这里把每一发的身体记下来并断言这一点，不留"以为测过"的假账。
fn stub_body_kind(body : @transport.RequestBody) -> String {
  match body {
    @transport.RequestBody::Empty => "Empty"
    @transport.RequestBody::Bytes(_) => "Bytes"
    @transport.RequestBody::Stream(_, _) => "Stream"
  }
}

///|
fn stub_verb_name(verb : @transport.Method) -> String {
  match verb {
    @transport.Method::Get => "GET"
    @transport.Method::Head => "HEAD"
    @transport.Method::Put => "PUT"
    @transport.Method::Post => "POST"
    @transport.Method::Delete => "DELETE"
    @transport.Method::Patch => "PATCH"
    @transport.Method::Options => "OPTIONS"
  }
}

///|
/// 一发的正文（计数与断言都用整串，桩件不切片）。
fn stub_bytes(text : String) -> Bytes {
  @utf8.encode(text.view())
}

///|
fn stub_header(name : String, value : String) -> @transport.Header {
  @transport.Header::{ name, value, }
}

///|
/// 造一个只认桩传输的客户端。桩不发网络，凭据用假值（形状件同一条口径）。
fn stub_client(stub : StubTransport) -> @obs.Client raise @error.ObsError {
  let transport : &@transport.Transport = stub
  let credentials = @auth.Credentials::new(
    "AKFORSTUBONLY0000000", "SKFORSTUBONLY000000000000000000000000000000",
  )
  @obs.Client::new(
    @config.Config::from_region("cn-south-1", credentials),
    transport,
  )
}

///|
/// 正常应答的桩（200 + 正文）。`die_first` 由调用侧自己填，写在这里故意不默认。
fn stub_ok(
  answer : String,
  die_first~ : Int32 = 0,
  headers~ : Array[@transport.Header] = [],
) -> StubTransport {
  StubTransport::{
    sends: 0,
    lines: [],
    bodies: [],
    die_first,
    status: 200,
    headers,
    answer: stub_bytes(answer),
  }
}

///|
/// 协议层拒答的桩：状态码与服务端码都要能读出来，否则"读数原样交出"这一档断不住。
/// 它**从不死亡**（`die_first=0`），所以调用侧读到的 `sends` 就是"这一发总共发了几趟"。
fn stub_http_error(status : Int32, code : String) -> StubTransport {
  StubTransport::{
    sends: 0,
    lines: [],
    bodies: [],
    die_first: 0,
    status,
    headers: [stub_header("x-amz-request-id", "stub-request-id")],
    answer: stub_bytes(
      "<Error><Code>" +
      code +
      "</Code><Message>" +
      code +
      " by stub</Message></Error>",
    ),
  }
}

///|
/// **证据①（幂等档能恢复）**：GET／PUT／HEAD／DELETE／LIST 五档各造一次"响应头未到达"，
/// 断言 SDK 重发**一次**并真拿到应答；两发打的是同一条 URL（签名与查询串一字未动）。
async test "幂等档·响应头未到达就重发一次，之后拿到应答" {
  // GET 对象
  let get_stub = stub_ok("hello", die_first=1)
  let get_client = stub_client(get_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let got = get_client.get_object("examplebucket", "k.txt") catch {
    err => fail("get_object 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(get_stub.sends, 2)
  assert_eq(got.body.to_array(), stub_bytes("hello").to_array())
  assert_eq(get_stub.lines.length(), 2)
  assert_eq(get_stub.lines[0], get_stub.lines[1])
  assert_true(get_stub.lines[0].has_prefix("GET "))
  println(
    "证据①·GET 重发后拿到应答: sends=" +
    get_stub.sends.to_string() +
    " 两发同串=" +
    (get_stub.lines[0] == get_stub.lines[1]).to_string(),
  )

  // PUT 对象
  let put_stub = stub_ok("", die_first=1)
  let put_client = stub_client(put_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let _ = put_client.put_object("examplebucket", "k.txt", stub_bytes("payload")) catch {
    err => fail("put_object 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(put_stub.sends, 2)
  assert_true(put_stub.lines[0].has_prefix("PUT "))

  // HEAD（stat）
  let head_stub = stub_ok("", die_first=1, headers=[
    stub_header("content-length", "7"),
  ])
  let head_client = stub_client(head_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let stat = head_client.stat_object("examplebucket", "k.txt") catch {
    err => fail("stat_object 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(head_stub.sends, 2)
  assert_eq(stat.size, 7L)
  assert_true(head_stub.lines[0].has_prefix("HEAD "))

  // DELETE
  let del_stub = stub_ok("", die_first=1)
  let del_client = stub_client(del_stub) catch {
    err => fail("stub client: " + err.text())
  }
  del_client.delete_object("examplebucket", "k.txt") catch {
    err =>
      fail("delete_object 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(del_stub.sends, 2)
  assert_true(del_stub.lines[0].has_prefix("DELETE "))

  // LIST
  let list_stub = stub_ok(
    "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.txt</Key><Size>1</Size></Contents></ListBucketResult>",
    die_first=1,
  )
  let list_client = stub_client(list_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let listing = list_client.list_objects("examplebucket") catch {
    err => fail("list_objects 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(list_stub.sends, 2)
  assert_eq(listing.objects.length(), 1)

  // 复制那一发也是 PUT（键幂等：同源同目标再覆写一次同果）
  let copy_stub = stub_ok(
    "<CopyObjectResult><ETag>&quot;stub&quot;</ETag></CopyObjectResult>",
    die_first=1,
  )
  let copy_client = stub_client(copy_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let _ = copy_client.copy_object(
    "examplebucket", "src.txt", "examplebucket", "dst.txt",
  ) catch {
    err => fail("copy_object 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(copy_stub.sends, 2)

  // ACL 两档（PUT ?acl 与 GET ?acl）同属幂等档。各配一支桩：`die_first` 数的是**这一支**
  // 的第几发，共用一支就会把"第二档的第一发"读成"没死亡的那一发"，判据当场失真。
  let acl_put_stub = stub_ok("", die_first=1)
  let acl_put_client = stub_client(acl_put_stub) catch {
    err => fail("stub client: " + err.text())
  }
  acl_put_client.put_object_acl("examplebucket", "k.txt", "private") catch {
    err =>
      fail("put_object_acl 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(acl_put_stub.sends, 2)
  assert_true(acl_put_stub.lines[0].contains("acl="))
  let acl_get_stub = stub_ok(
    "<AccessControlPolicy><AccessGrants><Grant><Permission>FULL_CONTROL</Permission></Grant></AccessGrants></AccessControlPolicy>",
    die_first=1,
  )
  let acl_get_client = stub_client(acl_get_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let _ = acl_get_client.get_object_acl("examplebucket", "k.txt") catch {
    err =>
      fail("get_object_acl 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(acl_get_stub.sends, 2)
}

///|
/// **证据①的边界**：两发都死亡时总共就发两发——第三趟没有，重发**恰好一次**。
async test "幂等档·重发只有一次，第二发仍死亡就交回死亡" {
  let stub = stub_ok("hello", die_first=2)
  let client = stub_client(stub) catch {
    err => fail("stub client: " + err.text())
  }
  let note = try {
    let _ = client.get_object("examplebucket", "k.txt")
    "no-error"
  } catch {
    err => err.text()
  }
  println("证据①·两发都死亡的读数=" + note)
  assert_true(note.has_prefix("obs network:"))
  assert_true(note.contains("stub: died before any response header"))
  assert_eq(stub.sends, 2)
}

///|
/// **证据②（POST 档证明没重发）**：`?uploads` 与 `?uploadId` 两发死亡时 `sends` 必须停在 1，
/// 且桩件从没回过 200 ⇒ 这一档**一个 uploadId 都没产生**（`ids` 那一只装得住 200 的读数）。
/// 对照格：上传分片那一发是 PUT，落点由 (uploadId, 分片号, 同一份字节) 定死 ⇒ 允许重发。
async test "非幂等档·POST 两发死亡都只发一次，绝不重发" {
  // 建分片任务那一发
  let init_stub = stub_ok("", die_first=1)
  let init_client = stub_client(init_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let init_ids : Array[String] = []
  let init_note = try {
    let id = init_client.create_multipart_upload("examplebucket", "k.bin")
    init_ids.push(id)
    "no-error"
  } catch {
    err => err.text()
  }
  assert_true(init_note.has_prefix("obs network:"))
  // 拿到 uploadId 的唯一入口是 200 那一发，而这一档根本没拿到应答
  assert_eq(init_ids.length(), 0)
  assert_eq(init_stub.sends, 1)
  println(
    "证据②·POST ?uploads 读数: sends=" +
    init_stub.sends.to_string() +
    " uploadId 计数=" +
    init_ids.length().to_string() +
    " 结果=" +
    init_note,
  )

  // 合并分片那一发
  let done_stub = stub_ok("", die_first=1)
  let done_client = stub_client(done_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let done_note = try {
    let _ = done_client.complete_multipart_upload(
      "examplebucket",
      "k.bin",
      "stub-upload-id",
      [(1, "\"etag\"")],
    )
    "no-error"
  } catch {
    err => err.text()
  }
  assert_true(done_note.has_prefix("obs network:"))
  assert_eq(done_stub.sends, 1)
  println(
    "证据②·POST ?uploadId 读数: sends=" +
    done_stub.sends.to_string() +
    " 结果=" +
    done_note,
  )

  // 对照：分片那一发（PUT）允许重发，且重发打的还是同一条带 uploadId 与分片号的 URL
  let part_stub = stub_ok("", die_first=1, headers=[
    stub_header("etag", "\"stub-etag\""),
  ])
  let part_client = stub_client(part_stub) catch {
    err => fail("stub client: " + err.text())
  }
  let etag = part_client.upload_part(
    "examplebucket",
    "k.bin",
    "stub-upload-id",
    1,
    stub_bytes("a"),
  ) catch {
    err => fail("upload_part 本该由重发兜住，却抛出: " + err.text())
  }
  assert_eq(part_stub.sends, 2)
  assert_eq(etag, "\"stub-etag\"")
  assert_true(part_stub.lines[0].contains("uploadId=stub-upload-id"))
  assert_eq(part_stub.lines[0], part_stub.lines[1])

  // 放弃分片是 DELETE（幂等）⇒ 允许重发
  let abort_stub = stub_ok("", die_first=1)
  let abort_client = stub_client(abort_stub) catch {
    err => fail("stub client: " + err.text())
  }
  abort_client.abort_multipart_upload(
    "examplebucket", "k.bin", "stub-upload-id",
  ) catch {
    err =>
      fail(
        "abort_multipart_upload 本该由重发兜住，却抛出: " +
        err.text(),
      )
  }
  assert_eq(abort_stub.sends, 2)

  // 顺带记一笔可达性：这一族公开面交出去的身体只有 `Empty`／`Bytes`，
  // 所以"流式体一律不重发"那道闸门在本轮真发里**没被触发**（不是"触发过且通过"）。
  let kinds : Array[String] = init_stub.bodies +
    done_stub.bodies +
    part_stub.bodies
  println("证据②·这几发的身体=" + kinds.join(","))
  for kind in kinds {
    assert_true(kind == "Empty" || kind == "Bytes")
  }
}

///|
/// **证据③（4xx 证明没重发）**：状态码一到就算"应答已到达"，原样抛出且总共只发了一发——
/// 没有第二发，那条 `[moon-obs] resending` 日志也就没有出现的场合（它只可能在第二次 send 之前打）。
async test "协议层读数·404 与 403 与 503 原样抛出不重发" {
  let readings : Array[(String, Int32)] = []
  let cases : Array[(String, Int32, String)] = [
    ("get", 404, "NoSuchKey"),
    ("stat", 403, "SignatureDoesNotMatch"),
    ("delete", 503, "InternalError"),
  ]
  for case in cases {
    let stub = stub_http_error(case.1, case.2)
    let client = stub_client(stub) catch {
      err => fail("stub client: " + err.text())
    }
    let note = try {
      match case.0 {
        "get" => {
          let _ = client.get_object("examplebucket", "missing.txt")
        }
        "stat" => {
          let _ = client.stat_object("examplebucket", "k.txt")
        }
        _ => client.delete_object("examplebucket", "k.txt")
      }
      "no-error"
    } catch {
      err => err.text()
    }
    println(
      "证据③·" +
      case.0 +
      " 回 " +
      case.1.to_string() +
      " 那一发：读数=" +
      note +
      " sends=" +
      stub.sends.to_string(),
    )
    // `Service` 那一臂的原文就是 `<状态码> <服务端码>: <正文 Message>`（错误面在 `error/error.mbt`），
    // 三件都在 ⇒ 协议层读数没被折成"网络断"也没被折成"不存在"。
    assert_true(note.has_prefix(case.1.to_string() + " " + case.2 + ":"))
    readings.push((note, stub.sends))
  }
  // 三档各自只发了一发：应答已到达，一次都没重发
  for reading in readings {
    assert_eq(reading.1, 1)
  }

  // 状态码／服务端码／请求号三件都要原样在（不许折成"不存在"或"网络断"）
  let shaped = stub_http_error(404, "NoSuchKey")
  let shaped_client = stub_client(shaped) catch {
    err => fail("stub client: " + err.text())
  }
  let typed = try {
    let _ = shaped_client.get_object("examplebucket", "missing.txt")
    "no-error"
  } catch {
    @error.ObsError::Service(details) =>
      "status=" +
      details.status.to_string() +
      " code=" +
      details.code +
      " id=" +
      details.request_id.unwrap_or("-")
    err => "other:" + err.text()
  }
  assert_eq(typed, "status=404 code=NoSuchKey id=stub-request-id")
  assert_eq(shaped.sends, 1)
}

///|
/// 坏形状必须报红，且理由里要钉得住那句话说的是**哪一种**坏（放行与"报了个不相干的红"
/// 都不算守住）。
fn rl_must_be_red(cell : String, verdict : String?, want : String) -> Unit {
  match verdict {
    None => abort(cell + " 本该报红，判据却放行了")
    Some(reason) =>
      if !reason.contains(want) {
        abort(
          cell +
          " 报了红但没钉住「" +
          want +
          "」，实际理由：" +
          reason,
        )
      }
  }
}

///|
/// `rl_send_shape_verdict` 的正反对照（真桶那一档的判据本身）。为什么放在离线档：真桶只在网络
/// 配合时才走"两发"分支，让它自己证明"敢红"等于没证明——2026-10-21 本机就是被一条真实超时逼出
/// 这个形状的。合法两种、坏的五种，一条都不许放过。
test "重发档的每一发下场形状：两种合法、五种坏形状各自报红" {
  assert_eq(rl_send_shape_verdict(["answered"]), None)
  assert_eq(rl_send_shape_verdict(["died-before-response", "answered"]), None)

  // 桩档自己就是这条判据的内部阳性对照：die_first=1 的 GET 在真桶那一头产出的正是
  // `died-before-response → answered` 这个形状（证据①），不是纸上画的。
  rl_must_be_red(
    "一发都没拿到应答",
    rl_send_shape_verdict(["died-before-response"]),
    "状态码没交到调用方",
  )
  rl_must_be_red(
    "应答之后还发第二趟",
    rl_send_shape_verdict(["answered", "answered"]),
    "应答到达过就不许重发",
  )
  rl_must_be_red(
    "重发那一发仍没拿到应答",
    rl_send_shape_verdict(["died-before-response", "died-before-response"]),
    "不重发第三次",
  )
  rl_must_be_red(
    "三发以上",
    rl_send_shape_verdict(["died-before-response", "answered", "answered"]),
    "政策上限是 2 发",
  )
  // 一发都没数到＝那一档根本没跑，判据不许对空形状放行
  rl_must_be_red("空形状", rl_send_shape_verdict([]), "总共发了 0 发")
}
