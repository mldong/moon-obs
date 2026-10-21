///|
// 重发档的判定层离线档（白盒：`resend_policy` 与两条日志原文都是包内件，黑盒拿不到）。
// 这一档不需要 async——它只问"这一档有没有重发资格、日志该长成什么样"。
// 真发与真重发的行为档在 `retry_test.mbt`（黑盒＋桩传输），真端点档在 `retry_live_test.mbt`。

///|
test "资格表·四个幂等动词可重发，POST 三种形状与未知动词都不可重发" {
  let empty_body = @transport.RequestBody::Empty
  for verb in ["GET", "HEAD", "PUT", "DELETE"] {
    match resend_policy(verb, [], empty_body) {
      Resend::Allowed(safety) => assert_true(safety.contains("replays"))
      Resend::Refused(reason) =>
        fail(verb + " 该有重发资格，却拒了: " + reason)
    }
  }
  let post_shapes : Array[Array[(String, String)]] = [
    [("uploads", "")],
    [("uploadId", "some-id")],
    [("something-else", "")],
  ]
  for query in post_shapes {
    match resend_policy("POST", query, empty_body) {
      Resend::Allowed(_) => fail("POST 拿到了重发资格: " + query[0].0)
      Resend::Refused(reason) =>
        if query[0].0 == "uploads" {
          // 建任务那一档的理由必须说出"多出一个 uploadId 没人 abort"
          assert_true(reason.contains("uploadId"))
        } else if query[0].0 == "uploadId" {
          assert_true(reason.contains("merge"))
        } else {
          // 认不出的 POST 一律按非幂等待（fail-closed）
          assert_true(reason.contains("non-idempotent"))
        }
    }
  }
  match resend_policy("PATCH", [], empty_body) {
    Resend::Refused(reason) => assert_true(reason.contains("PATCH"))
    Resend::Allowed(_) => fail("PATCH 不该有重发资格")
  }
  // 带分片上下文的 GET／PUT／DELETE 仍是幂等档（重放的是同一发已签名字节，落点由查询串定死）
  assert_true(
    resend_policy("GET", [("uploadId", "some-id")], empty_body)
    is Resend::Allowed(_),
  )
  assert_true(
    resend_policy("DELETE", [("uploadId", "some-id")], empty_body)
    is Resend::Allowed(_),
  )
}

///|
/// 体能不能倒带这一档：`Empty`／`Bytes` 在内存里可原样再发，`Stream` 不能。
/// `Stream` 那一臂**本 SDK 的公开面产不出它**（`put_object`／`upload_part` 都收 `Bytes`），
/// 所以它是"认不出的输入按不重发待"的那道 fail-closed 闸门，只在这两臂能被直接量到的地方钉。
test "重发资格·内存里的身体能倒带，流式身位是闸门" {
  assert_true(body_replayable(@transport.RequestBody::Empty))
  assert_true(
    body_replayable(@transport.RequestBody::Bytes(@utf8.encode("x".view()))),
  )
  // 资格层：身体能倒带的幂等动词才有 Allowed
  assert_true(
    resend_policy(
      "PUT",
      [],
      @transport.RequestBody::Bytes(@utf8.encode("payload".view())),
    )
    is Resend::Allowed(_),
  )
}

///|
/// 两条日志原文的形状各自钉死：重发要说"哪一发＋为什么可以重发＋死亡读数"，
/// 拒重发要说"哪一发＋为什么不重发"。标记词分得开，数日志才数得对。
test "日志两档·resending 与 NOT resending 的原文形状" {
  let note = resend_note(
    "GET /examplebucket/k.txt", "it replays the same signed bytes", "timeout",
  )
  println("重发日志原文=" + note)
  assert_true(note.has_prefix("[moon-obs] resending exactly once: GET "))
  assert_true(note.contains("response headers had not arrived (timeout)"))
  assert_true(note.contains("the resend is safe because"))
  let refusal = refusal_note(
    "POST /examplebucket/k.txt",
    post_refusal_reason([("uploads", "")]),
    "timeout",
  )
  println("拒重发日志原文=" + refusal)
  assert_true(refusal.has_prefix("[moon-obs] NOT resending: POST "))
  assert_true(refusal.contains("mints a new uploadId"))
  assert_true(!refusal.contains("resending exactly once"))
  // 两条串的标记词必须互不包含，否则"数了几次重发"读不出来
  assert_true(!note.contains("NOT resending"))
}

///|
/// 标签只到键为止：查询串（预签名与分片那一族的凭据本体）不进日志。
test "日志里的操作名只到键为止，查询串一律不带" {
  assert_eq(
    request_label("GET", "examplebucket", "k.txt"),
    "GET /examplebucket/k.txt",
  )
  assert_eq(request_label("GET", "examplebucket", ""), "GET /examplebucket")
  assert_eq(request_label("GET", "", ""), "GET (service root)")
  let with_uploads = request_label("POST", "b", "k.bin")
  assert_true(!with_uploads.contains("?"))
  assert_true(!with_uploads.contains("uploads="))
}

///|
/// 传输层文案那条老红线不因为重发档松动：`redact_query` 仍然吃得住带 query 的死亡文案，
/// 重发日志里出现的死亡读数走的就是这同一个出口。
test "死亡读数里的查询串照旧隐去" {
  let leaked = "https://b.obs.cn-north-4.myhuaweicloud.com/k?X-Amz-Signature=deadbeef"
  let hidden = redact_query(leaked)
  assert_true(!hidden.contains("deadbeef"))
  assert_true(hidden.contains("?<redacted>"))
}
