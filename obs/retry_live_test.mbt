///|
// 真桶上的重发档（凭据只从环境读，**绝不打印值**）。这一档把离线桩那三条证据在**真端点**上各量一遍：
// · 证据①：掐掉第一发（模拟"响应头未到达"）⇒ SDK 重发一次，对象**真落进桶**；
// · 证据②：掐掉建分片任务那一发 ⇒ 总共只发一趟（`sends=1`），并且 `GET ?uploads` 复列该键的
//   `UploadId` 计数为 0；同轮再拿成功那一发做对照，计数必须是**恰好 1**（不是"没数过"）；
// · 证据③：读一个不存在的键（404）与错密钥那一发（签名层拒）⇒ 状态码原样抛出，且**应答到达之后
//   一次都不重发**。打公网这一档不许钉死 `sends=1`：第一发完全没拿到应答时，按 A 档政策重发一次
//   正是它该做的（2026-10-21 本机实测：HEAD 的第一发把 30 秒默认超时用满，第二发才拿到 403）。
//   判据改成看每一发的下场——`answered`（红线档：到此为止）、`died-before-response → answered`
//   （政策允许的那一次重发）两种算过，其余形状一律红。"应答到达后不许重发"这条红线由离线桩那一头
//   （桩件从不死亡、必回 403）钉死，本档不替它背书。
//
// 掐线的是**注入的传输层**（`Transport` 端口是开放 trait），SDK 看到的就是普通的传输层死亡，
// 与公网抖一下那种死法在它眼里没有区别——这正是这条线要的形状。
//
// 前缀：`moonfs-live-<YYYYMMDD>/obs-native-<运行号>-retry-`（本轮独占，口径与 `live_test.mbt` 一致）。
// 清扫纪律同样照那一档：开头无条件扫一次 + 阳性对照已在它里面跑过 + 结尾清扫排在断言之前。
// 分片任务额外有收尾兜底：中途红也要把本轮建出来的 uploadId abort 掉（对象扫不到未合并的分片）。

///|
/// 计数与掐线用的传输壳。`die_first` ＝**前 N 发按脚本掐线**（根本不放到线上），
/// 之后一律交给真传输。`sends` 是"这一发总共发了几趟"的唯一读数口。
///
/// `outs` 记每一发的**下场**（`injected-death`／`died-before-response`／`answered`）。
/// 打公网那一档必须有它：判据要区分"应答到达过所以不许重发"与"第一发就没拿到应答、
/// 按政策重发过一次"——前者是政策红线，后者是政策允许的档位，只看 `sends` 分不开这两种。
struct CountingTransport {
  inner : &@transport.Transport
  mut sends : Int32
  lines : Array[String]
  outs : Array[String]
  die_first : Int32
}

///|
impl @transport.Transport for CountingTransport with fn send(self, request) {
  self.sends = self.sends + 1
  self.lines.push(rl_verb_name(request.http_method) + " " + request.url)
  // `errdefer` 而不是 `try/catch` 记死亡：这一版编译器明确警告"用 catch 做清理"对异步代码
  // 是危险写法（将来 catch 不再捕获取消），清理归清理、看错误归看错误。
  // 位置在掐线那一发**之前**：注入的死亡与真超时必须记成同一个形状，否则桩档与真桶档
  // 会因"记法不同"而不是"行为不同"分叉。
  errdefer self.outs.push("died-before-response")
  if self.sends <= self.die_first {
    raise @transport.TransportError::Network(
      "rl-probe: killed on purpose before any response header",
    )
  }
  let response = self.inner.send(request)
  self.outs.push("answered")
  response
}

///|
/// 每一发下场拼成的形状该怎么判。返回 `Some(原因)` 就是红，`None` 是合法：
/// · 1 发且 `answered`——网络没死，红线档：应答到达后不许再发；
/// · 2 发且 `died-before-response → answered`——政策允许的那一次重发；
/// · 其余一律红：应答之后还发、两发都没拿到应答、三发以上。
/// 这一档是**纯函数**，正反两种形状都在 `retry_test.mbt` 离线钉住（判据本身要能被证伪）。
fn rl_send_shape_verdict(outs : Array[String]) -> String? {
  let n = outs.length()
  if n == 1 {
    if outs[0] == "answered" {
      None
    } else {
      Some(
        "只发了一发，而那一发的下场是 " +
        outs[0] +
        "：状态码没交到调用方",
      )
    }
  } else if n == 2 {
    if outs[0] != "died-before-response" {
      Some(
        "发了两发，而第一发的下场是 " +
        outs[0] +
        "：应答到达过就不许重发，这是重发纪律被踩",
      )
    } else if outs[1] != "answered" {
      Some(
        "重发的那一发仍然没拿到应答（" +
        outs[1] +
        "）：这一档不重发第三次",
      )
    } else {
      None
    }
  } else {
    let head = "总共发了 " +
      n.to_string() +
      " 发（下场：" +
      outs.join(" → ")
    Some(head + "）：政策上限是 2 发")
  }
}

///|
fn rl_assert_delivered_without_retry_after_answer(
  cell : String,
  counter : CountingTransport,
) -> Unit {
  let shape = counter.outs.join(" → ")
  match rl_send_shape_verdict(counter.outs) {
    Some(reason) =>
      abort(cell + " 的每一发下场是 " + shape + "：" + reason)
    None => ()
  }
  println(cell + " 每一发的下场=" + shape)
}

///|
fn rl_verb_name(verb : @transport.Method) -> String {
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
/// 造一个"计数壳包真传输"的客户端。`secret` 可以故意给错（签名层那一发的夹具）。
fn rl_build(
  ak : String,
  sk : String,
  region : String,
  die_first : Int32,
) -> (@obs.Client, CountingTransport) raise @error.ObsError {
  let inner : &@transport.Transport = @transport.AsyncHttpTransport::new()
  let counting = CountingTransport::{
    inner,
    sends: 0,
    lines: [],
    outs: [],
    die_first,
  }
  let transport : &@transport.Transport = counting
  let credentials = @auth.Credentials::new(ak, sk)
  let client = @obs.Client::new(
    @config.Config::from_region(region, credentials),
    transport,
  )
  (client, counting)
}

///|
/// 复列某个键下**未完成的分片任务**个数。`GET /<bucket>/?uploads&prefix=<key>` 走手签探针
/// （SDK 公开面没有 list_multipart_uploads，这一发本来就不在承诺面里，量它不等于把它端上承诺面）。
/// 返回 `(UploadId 个数, 回体里的键名读数)`；传输层拿不到应答时 raise，由调用侧分档。
async fn rl_upload_id_count(
  client : @obs.Client,
  bucket : String,
  key : String,
) -> (Int32, String) raise @error.ObsError {
  let config = client.config_of()
  let host = config.host_of(bucket)
  let wire_url = config.url_of(bucket)
  let (status, body, _) = live_probe(client, host, "/", wire_url, "GET", [
    ("uploads", ""),
    ("prefix", key),
  ])
  if status >= 400 {
    raise @error.Service(@error.ServiceError::{
      status,
      code: @obs.xml_error_code(body),
      message: live_or_blank(@obs.xml_first(body, "Message")),
      request_id: None,
    })
  }
  let ids = @obs.xml_all(body, "UploadId")
  let keys = @obs.xml_all(body, "Key")
  (ids.length(), "键=" + live_trim(keys.join(","), 120))
}

///|
/// 测量段：三条证据各量一遍，串行跑在同一个体里（wasm 跑批里同包的 async 用例是**并发**的）。
/// `created` 收集本轮真建出来的 (键, uploadId)，交调用侧在收尾里 abort。
/// 签名用**裸 `raise`**（不带错误类型）：这一体里既要 `fail`／`assert_*`（判据），
/// 也要让 `ObsError` 原样冒出去（收尾兜底），带类型的 `raise E` 装不下前者。
async fn rl_measure(
  bucket : String,
  region : String,
  ak : String,
  sk : String,
  prefix : String,
  created : Array[(String, String)],
) -> Unit {
  let plain = live_build(ak, sk, region)
  let body = live_bytes(
    "重发档真桶夹具，掐掉第一发之后要由第二次拿到应答",
  )

  // —— 证据①：幂等档掐掉第一发，重发一次之后对象真落进桶 ——
  let key_one = prefix + "/resend-put.txt"
  let (put_client, put_counter) = rl_build(ak, sk, region, 1)
  let _ = put_client.put_object(bucket, key_one, body) catch {
    err =>
      fail(
        "证据①·掐掉第一发的 PUT 本该由重发兜住，却抛出: " +
        live_code(err),
      )
  }
  println(
    "证据①·真桶 PUT 掐第一发 -> 总共发了 " +
    put_counter.sends.to_string() +
    " 趟（期望 2：一发掐线 + 一发改到线上）",
  )
  assert_eq(put_counter.sends, 2)
  // 重发那一发是真打上线的：对象存在、尺寸对得上，才算"恢复"而不是"没报错"
  let stat = plain.stat_object(bucket, key_one) catch {
    err =>
      fail("证据①·重发之后 stat 读不到对象: " + live_code(err))
  }
  println(
    "证据①·重发之后 stat=" +
    stat.size.to_string() +
    " 期望=" +
    body.length().to_string(),
  )
  assert_eq(stat.size, body.length().to_int64())
  assert_eq(put_counter.lines.length(), 2)
  // 两发打的是同一条 URL（签名与查询串一字未动）。这里**不**用 assert_eq：
  // URL 里带着测试桶名，红的时候 diff 会把整串抄进日志，所以只断布尔读数。
  assert_true(put_counter.lines[0] == put_counter.lines[1])

  // 读对象那一发同档：掐第一发 ⇒ 重发后真读回刚写进去的字节
  let (get_client, get_counter) = rl_build(ak, sk, region, 1)
  let got = get_client.get_object(bucket, key_one) catch {
    err =>
      fail(
        "证据①·掐掉第一发的 GET 本该由重发兜住，却抛出: " +
        live_code(err),
      )
  }
  assert_eq(get_counter.sends, 2)
  assert_eq(got.body.to_array(), body.to_array())
  println(
    "证据①·真桶 GET 掐第一发 -> sends=2 且逐字节读回一致",
  )

  // —— 证据②：非幂等档。掐掉建分片任务那一发 ⇒ 一次都不重发、也没有第二个 uploadId ——
  let key_two = prefix + "/resend-multipart.bin"
  let (init_client, init_counter) = rl_build(ak, sk, region, 1)
  let init_note = try {
    let id = init_client.create_multipart_upload(bucket, key_two)
    created.push((key_two, id))
    "no-error"
  } catch {
    err => live_code(err)
  }
  println(
    "证据②·真桶 POST ?uploads 掐第一发 -> sends=" +
    init_counter.sends.to_string() +
    " 读数=" +
    init_note +
    "（那一发根本没放到线上，桶里不可能多出 uploadId）",
  )
  assert_true(init_note.has_prefix("network:"))
  assert_eq(init_counter.sends, 1)
  // 复列该键的未完成分片任务：必须是 0 个
  let (killed_count, killed_note) = rl_upload_id_count(plain, bucket, key_two)
  println(
    "证据②·掐线那一发之后复列 " +
    key_two +
    " 的 UploadId 个数=" +
    killed_count.to_string() +
    " " +
    killed_note,
  )
  assert_eq(killed_count, 0)

  // 对照：同一发不打线上打到成功 ⇒ 恰好 1 个 uploadId（"计数"这一格不是空转）
  let ok_id = plain.create_multipart_upload(bucket, key_two) catch {
    err => fail("证据②·对照那一发建任务失败: " + live_code(err))
  }
  created.push((key_two, ok_id))
  let (ok_count, ok_note) = rl_upload_id_count(plain, bucket, key_two)
  println(
    "证据②·对照（成功那一发）复列 UploadId 个数=" +
    ok_count.to_string() +
    " " +
    ok_note,
  )
  assert_eq(ok_count, 1)

  // —— 证据③：4xx 与 5xx 都是"应答已到达" ⇒ 原样抛出、一次都不重发 ——
  let missing_key = prefix + "/never-written.txt"
  let (n4_client, n4_counter) = rl_build(ak, sk, region, 0)
  let four_0_4 = try {
    let _ = n4_client.get_object(bucket, missing_key)
    "no-error"
  } catch {
    err => err.text()
  }
  println(
    "证据③·真桶读不存在的键=" +
    four_0_4 +
    " sends=" +
    n4_counter.sends.to_string(),
  )
  assert_true(four_0_4.has_prefix("404 "))
  rl_assert_delivered_without_retry_after_answer(
    "证据③·真桶读不存在的键", n4_counter,
  )

  // 错密钥那一发：签名层拒。判据是"状态码原样交出、且没被折成网络断、且一次都不重发"。
  // 走 GET 不走 HEAD：本轮实测 `HEAD` 的 403 **没有正文**，`<Code>` 读出来是空串
  // （读数 `403 : `），要拿服务端码当读数就得有一条能带回体的路。
  let (bad_client, bad_counter) = rl_build(ak, sk + "zz", region, 0)
  let denied = try {
    let _ = bad_client.get_object(bucket, key_one)
    "no-error"
  } catch {
    err => err.text()
  }
  println(
    "证据③·真桶错密钥那一发=" +
    live_safe(denied, bucket) +
    " sends=" +
    bad_counter.sends.to_string(),
  )
  assert_true(denied.has_prefix("403 "))
  assert_true(!denied.contains("network"))
  rl_assert_delivered_without_retry_after_answer(
    "证据③·真桶错密钥那一发", bad_counter,
  )

  // HEAD 那一档也照一遍：同一个 403 在没正文的形状下仍然原样交出。发数按重发纪律判：
  // 应答到达过就到此为止；只有"第一发连应答都没拿到"才允许那一次重发。
  let (bad_head_client, bad_head_counter) = rl_build(ak, sk + "zz", region, 0)
  let denied_head = try {
    let _ = bad_head_client.stat_object(bucket, key_one)
    "no-error"
  } catch {
    err => err.text()
  }
  println(
    "证据③·真桶错密钥 HEAD（无正文）那一发=" +
    live_safe(denied_head, bucket) +
    " sends=" +
    bad_head_counter.sends.to_string(),
  )
  assert_true(denied_head.has_prefix("403 "))
  rl_assert_delivered_without_retry_after_answer(
    "证据③·真桶错密钥 HEAD", bad_head_counter,
  )
}

///|
async test "真桶·重发档：幂等档掐一发能恢复，POST 与 4xx 一次都不重发" {
  match live_env() {
    None => live_skip()
    Some(environment) => {
      let bucket = environment.2
      let root = live_root() catch { err => fail("root: " + err.text()) }
      let client = live_build(environment.0, environment.1, environment.3) catch {
        err => fail("setup: " + err.text())
      }
      let prefix = root + "retry-"
      live_open_clean(client, bucket, prefix, "重发档")
      let created : Array[(String, String)] = []
      let outcome = try {
        rl_measure(
          bucket,
          environment.3,
          environment.0,
          environment.1,
          prefix,
          created,
        )
        "no-error"
      } catch {
        err => "重发档 测量阶段红: " + err.to_string()
      }
      // 收尾：本轮建出来的分片任务先 abort 掉（未合并的分片对象扫不到，只能按 uploadId 删）
      for pair in created {
        let note = try {
          client.abort_multipart_upload(bucket, pair.0, pair.1)
          "ok"
        } catch {
          err => live_code(err)
        }
        println(
          "收尾 abort 分片任务 " +
          live_trim(pair.0, 80) +
          "（uploadId 长度" +
          pair.1.length().to_string() +
          "）-> " +
          note,
        )
      }
      let (left_ids, left_note) = rl_upload_id_count(client, bucket, prefix) catch {
        err => (-1, "error:" + live_code(err))
      }
      println(
        "收尾 复列本轮前缀的 UploadId 个数=" +
        left_ids.to_string() +
        " " +
        left_note,
      )
      live_close_clean(client, bucket, prefix, "重发档", outcome)
      // 分片任务也要归零（对象清扫管不到它，这一格只能单独断）
      assert_eq(left_ids, 0)
    }
  }
}
