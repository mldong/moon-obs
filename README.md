# mldong/moon-obs

华为云对象存储（OBS）**原生协议**客户端的 MoonBit 版，签名走官方 V4
（算法串 `AWS4-HMAC-SHA256`，scope 服务名 `s3`）。头名前缀按真桶实测钉在 `x-amz-`：
原生端点上 V4 这一族只认 `x-amz-date`／`x-amz-content-sha256`／`x-amz-acl`，
换 `x-obs-*` 会回 `400 InvalidArgument`／`400 MissingSecurityHeader`
（读数与参照实现的对证写在 `obs/client.mbt` 的 `signed_prefix` 那段）。

```bash
moon add mldong/moon-obs
```

寻址只有虚主机一档（`<bucket>.obs.<region>.myhuaweicloud.com`）：path 风格在真端点回
403 `VirtualHostDomainRequired`，所以这里没有 `addressing_style` 这类开关，调用 path 风格
当场 `BadParam`。

## 最小用法

```moonbit
/// `sign_v4` 会 raise（时间戳形状、空密钥这两类本地就能判死的输入），文档块里把它兜住：
/// 这一块演示的是"本地算得出"的那一半，兜住不等于演示失败路径。
fn sign(
  access_key : String,
  secret_key : String,
  region : String,
  timestamp : String,
  req : @obsauth.RequestToSign,
) -> @obsauth.Signature {
  try {
    @obsauth.sign_v4(access_key, secret_key, region, timestamp, req)
  } catch {
    err => abort("最小用法只演示本地可算的一档，签名件不该在这里红：" + err.text())
  }
}

test "寻址、编码与签名串全在本地算得出，抄这一块不打网络" {
  // 基址按区域派生；虚主机那一档由桶名打头，Config::host_of 是唯一出口
  assert_eq(
    @obsconfig.native_endpoint_host("cn-north-4"),
    "obs.cn-north-4.myhuaweicloud.com",
  )
  // 对象键编码：斜杠保留、空格 %20、加号 %2B——签名侧与请求行用同一条规则
  assert_eq(
    @obsauth.uri_encode("articles/03 state+machine.png", keep_slash=true),
    "articles/03%20state%2Bmachine.png",
  )
  // 查询串：键、值各自编码，再按编码后的串整体排序，空值写 `acl=`（等号不能省）
  assert_eq(
    @obsauth.canonical_query_string([("prefix", "a b"), ("acl", "")]),
    "acl=&prefix=a%20b",
  )
  // 头值归一（首尾去掉、中间连续空白压成一个空格）＋头名字典序分号拼
  assert_eq(@obsauth.normalize_header_value("  padded   value  "), "padded value")
  assert_eq(@obsauth.signed_header_list(["x-amz-date", "host"]), "host;x-amz-date")
  // scope 的服务名写死 `s3`，算法串与 AWS 逐字相同——这两格错了不会报错，只会一直 403
  assert_eq(
    @obsauth.scope_of("20261016", "cn-north-4"),
    "20261016/cn-north-4/s3/aws4_request",
  )
  assert_eq(@obsauth.algorithm, "AWS4-HMAC-SHA256")
  assert_eq(@obsauth.unsigned_payload, "UNSIGNED-PAYLOAD")
  // 头名前缀：原生端点上 V4 这一族只认 x-amz-*，所以默认档就是 Amz
  assert_eq(@obsauth.HeaderPrefix::Amz.date_header(), "x-amz-date")
  // 用 AWS 官方 SigV4 测试凭据签一发（公开测试值，不是任何真密钥）。
  // Authorization 的拼法是"逗号后不带空格"——AWS SDK 发的是带空格那一形，两家服务端都收，
  // 但这里钉的是 OBS 官方 SDK 那串逐字形状。
  let signed = sign(
    "AKIDEXAMPLE",
    "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    "us-east-1",
    "20261016T010203Z",
    @obsauth.RequestToSign::new(
      "GET",
      "/examplebucket/plain.txt",
      headers=[
        ("host", "examplebucket.obs.us-east-1.myhuaweicloud.com"),
        ("x-amz-content-sha256", @obsauth.unsigned_payload),
        ("x-amz-date", "20261016T010203Z"),
      ],
      payload_hash=@obsauth.unsigned_payload,
    ),
  )
  assert_eq(signed.signed_headers, "host;x-amz-content-sha256;x-amz-date")
  let want_head = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261016/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature="
  assert_true(signed.authorization.has_prefix(want_head))
  // 密钥本体不许出现在签出来的任何一段里
  assert_eq(signed.string_to_sign.find("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), None)
}
```

发真请求那一头是 `@obs.Client`：它收一把 `@hutoolhttp.Transport`，用法与这条线上其余四件
原生 SDK 同形（`Config` → `Client` → 对象族／分片族／预签名／ACL），仓里没有一份"抄了就打网络"
的示例块——那是文档门禁的口径，不是能力缺项。

## 传输层死亡的重发纪律（行为，不是内部实现细节）

请求层对**每一发**只做一件事：**响应头没到达 ⇒ 至多重发一次；应答已到达 ⇒ 绝不重发**。
形状与这条线已经在用的 HTTP 连接池那一档同形（"应答前死掉可换新线重发一次，应答阶段失败绝不重试"）。

分档判据（`obs/request.mbt` 的 `resend_policy`）：

| 这一发 | 重发资格 | 为什么 |
|--------|----------|--------|
| `GET`／`HEAD`／`DELETE` | 有 | 落点由 (桶, 键, 查询串) 定死，重放的是同一发已签名字节 |
| `PUT`（写对象／写分片／复制／`?acl`） | 有 | 同上，键幂等：服务端重复执行与执行一次同果 |
| `POST ?uploads`（建分片任务） | **没有** | 重发会多出一个 `uploadId`，前一个没人 `abort` 就永远漏在桶里 |
| `POST ?uploadId=`（合并分片） | **没有** | 重发可能双份合并，或与第一发竞态 |
| 认不出的 `POST` | **没有** | 默认按非幂等待，不替服务端猜"大概没事" |
| 带 `Stream` 体的请求 | **没有** | 流式体倒不回来，重发可能把体发歪 |
| **拿到任何状态码**（4xx／5xx 都算） | **没有** | 协议层的红必须原样交给调用方，不许被"再发一次"藏起来 |

第二次仍拿不到应答，抛出的是 `ObsError::Network`（错误面没有新增变体，调用方不需要改代码）。
两档都**响亮打日志**，标记词各一个：

```
[moon-obs] resending exactly once: GET /<bucket>/<key> -- response headers had not arrived (...); the resend is safe because ...
[moon-obs] NOT resending: POST /<bucket>/<key> -- POST ?uploads mints a new uploadId, ...
```

日志里的操作名只到键为止：查询串一律不进日志（预签名与分片那一族的凭据本体就在 query 里）。

下面还有一层，别把它跟这一档读成同一层：依赖的 `moon-hutool/http` 连接池那一档自带
"从池里拿的线已经死了 ⇒ 换一条新线再发一次"（只在"应答不可能已开始"的阶段、且体可倒带时才触发）。
那是**线级**重连，本档是**操作级**重发，两层各自至多一次、互不代管；
最坏情况下一条请求最多上线 4 次（2×2），且只在幂等档上发生。

> 平台能力读数（原生面收不收 `list-type=2`、分片最小段尺寸、ACL 取值面与 grant 拼法、
> 预签名免凭据可否取回等）都由仓内的真桶实测档裁决，判据与打印口径见 `obs/live_test.mbt`
> 与 `obs/retry_live_test.mbt`；本文件不抄那些数字。
