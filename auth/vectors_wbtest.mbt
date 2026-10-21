///|
/// OBS V4 签名件的**离线向量档**。不联网、不打真桶，期望值一律来自本库之外的两份权威：
///
/// 1. **AWS 官方 SigV4 向量**（`moon-s3/sigv4/vectors_wbtest.mbt` 存的那批，只取输入与
///    期望签名，那个文件一字未改）。OBS 的算法串、scope 服务名、四条密钥链与 AWS 逐字相同
///    （`AWS4-HMAC-SHA256` / `<date>/<region>/s3/aws4_request` / `'AWS4'+SK` 起链），
///    所以**同一份规范化输入下我们算出的签名 hex 必须等于 AWS 向量里那个期望签名**——
///    这就是"外部权威"的断言，不是"自己算一遍再当成对的"。
/// 2. **一份独立参照实现**（PHP 标准库 `hash`/`hash_hmac` 按官方 Python SDK 的
///    `V4Authentication` 另写一遍）。它先用上面那四项 AWS 向量自检
///    （`get_plain`／`temporary_credentials`／`put_with_content_type`／`presigned_get`
///    四个签名逐字相符）才有资格给 OBS 专属档位（`x-obs-` 前缀、Authorization 拼法、
///    同名参数折叠）出期望值。参照脚本与读数留在仓外的临时目录，不进本仓。
///
/// 凭据是 AWS 向量那对公开测试值（`AKIDEXAMPLE` / `wJalr…EXAMPLEKEY`），不是任何真密钥。

///|
let obs_vec_ak = "AKIDEXAMPLE"

///|
let obs_vec_sk = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

///|
/// AWS 向量用的区域与时刻。
let obs_vec_region = "us-east-1"

///|
let obs_vec_ts = "20261016T010203Z"

///|
/// 空正文的 sha256（AWS 向量把它同时写进 `x-amz-content-sha256` 与第六行）。
let obs_vec_empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

///|
/// 2026-10-16T01:02:03Z 的 epoch 毫秒。注入时钟那一档靠它把门面与向量钉在一起，
/// 顺带钉住"签名要的是 UTC 读数"这条承重前提。
let obs_vec_millis : Int64 = 1792112523000L

///|
/// OBS 原生面专属档位用的区域与主机名（公开端点形状，不含任何内网地址）。
let obs_native_region = "cn-south-1"

///|
let obs_native_host = "obs.cn-south-1.myhuaweicloud.com"

///|
/// 参照实现给的 OBS 原生面期望签名（`x-obs-` 前缀 + `UNSIGNED-PAYLOAD`）。
let obs_native_signature = "6687606f712167f67171f8534dd9e872bb05f6fc6405f2d887dcbc722281eb81"

///|
fn obs_vec_sign(
  verb : String,
  uri : String,
  query~ : Array[(String, String)] = [],
  headers~ : Array[(String, String)] = [],
  payload_hash~ : String = unsigned_payload,
  region~ : String = obs_vec_region,
) -> Signature raise {
  sign_v4(
    obs_vec_ak,
    obs_vec_sk,
    region,
    obs_vec_ts,
    RequestToSign::new(verb, uri, query~, headers~, payload_hash~),
  )
}

///|
test "AWS 向量 get_plain：同一输入下 OBS 签出的 hex 必须等于 AWS 的期望签名" {
  let signed = obs_vec_sign(
    "GET",
    "/mldong/plain.txt",
    headers=[
      ("host", "minio.test:9000"),
      ("x-amz-content-sha256", obs_vec_empty_hash),
      ("x-amz-date", obs_vec_ts),
    ],
    payload_hash=obs_vec_empty_hash,
  )
  assert_eq(
    signed.canonical_request,
    "GET\n/mldong/plain.txt\n\nhost:minio.test:9000\nx-amz-content-sha256:" +
    obs_vec_empty_hash +
    "\nx-amz-date:20261016T010203Z\n\nhost;x-amz-content-sha256;x-amz-date\n" +
    obs_vec_empty_hash,
  )
  assert_eq(
    signed.string_to_sign,
    "AWS4-HMAC-SHA256\n20261016T010203Z\n20261016/us-east-1/s3/aws4_request\n67e16e7ffe1388439f22cef1417d014fd547ee4c25ff4d6873121d571ec34816",
  )
  assert_eq(signed.scope, "20261016/us-east-1/s3/aws4_request")
  assert_eq(
    signing_key_hex(obs_vec_sk, "20261016", obs_vec_region),
    "cd74bcbae49283abe23b273ff8d086a71364f5492365824f546476087f2e0dd3",
  )
  // 外部权威断言：期望签名来自 AWS 官方向量，不是本库的输出
  assert_eq(
    signed.signature,
    "5d022b971f38f00f583ad73f8b8a616b19546fe52518c9ff8a8f8df0c738e646",
  )
}

///|
test "AWS 向量 temporary_credentials：临时凭据那一头进签后仍与 AWS 对上" {
  let signed = obs_vec_sign(
    "GET",
    "/mldong/tmp.txt",
    query=[("acl", "")],
    headers=[
      ("host", "minio.test:9000"),
      ("x-amz-content-sha256", obs_vec_empty_hash),
      ("x-amz-date", obs_vec_ts),
      ("x-amz-security-token", "SESSION/TOKEN+value"),
    ],
    payload_hash=obs_vec_empty_hash,
  )
  // OBS 的空值参数写成 `acl=`（官方 SDK 的 `'%s=%s'`），与 OSS V4"光键名不带等号"反着来；
  // AWS 向量这一格同样是 `acl=`，所以这条也顺手钉住了三家在这格的取向。
  assert_eq(
    signed.canonical_request,
    "GET\n/mldong/tmp.txt\nacl=\nhost:minio.test:9000\nx-amz-content-sha256:" +
    obs_vec_empty_hash +
    "\nx-amz-date:20261016T010203Z\nx-amz-security-token:SESSION/TOKEN+value\n\nhost;x-amz-content-sha256;x-amz-date;x-amz-security-token\n" +
    obs_vec_empty_hash,
  )
  assert_eq(
    signed.signature,
    "3b7e102aa642ddb89f6c849b2ef87b8487ad0460d8385d5f77f0902e86f70d51",
  )
}

///|
test "AWS 向量 put_with_content_type：头名小写、值归一、全量入签三条一起过" {
  let payload = "808b59664b6adb9274e3bbd0766e7aec9659786c22fdb825c49ca7fda1c6236e"
  let signed = obs_vec_sign(
    "PUT",
    "/mldong/upload.bin",
    headers=[
      ("Content-Type", "application/octet-stream"),
      ("host", "minio.test:9000"),
      ("x-amz-content-sha256", payload),
      ("x-amz-date", obs_vec_ts),
      ("X-Mixed-Case", "  padded   value  "),
    ],
    payload_hash=payload,
  )
  assert_eq(
    signed.signed_headers,
    "content-type;host;x-amz-content-sha256;x-amz-date;x-mixed-case",
  )
  assert_eq(
    signed.canonical_request,
    "PUT\n/mldong/upload.bin\n\ncontent-type:application/octet-stream\nhost:minio.test:9000\nx-amz-content-sha256:" +
    payload +
    "\nx-amz-date:20261016T010203Z\nx-mixed-case:padded value\n\ncontent-type;host;x-amz-content-sha256;x-amz-date;x-mixed-case\n" +
    payload,
  )
  assert_eq(
    signed.signature,
    "88b9b20da316958d3066e17ea887539fa8946290ca0ebc5d501efd97e0c0d401",
  )
}

///|
test "AWS 向量 presigned_get：V4 查询串签名与 Header 签名共用同一条链" {
  let presigned = presign_v4(
    obs_vec_ak,
    obs_vec_sk,
    obs_vec_region,
    obs_vec_ts,
    3600L,
    RequestToSign::new(
      "GET",
      "/mldong/share.txt",
      query=[("response-content-disposition", "attachment")],
      // 只有 host 进签：负载声明那一头此时不能塞进来（正文未知）
      headers=[("host", "minio.test:9000")],
    ),
  )
  assert_eq(presigned.signed_headers, "host")
  assert_eq(
    presigned.query,
    "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDEXAMPLE%2F20261016%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261016T010203Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&response-content-disposition=attachment&X-Amz-Signature=27d7a8427054da8c5196a19d0efb15dd8c0fa02d96bab7b702e5b1c48e322f90",
  )
  // 外部权威：AWS 向量里那个预签名期望值
  assert_eq(
    presigned.signature,
    "27d7a8427054da8c5196a19d0efb15dd8c0fa02d96bab7b702e5b1c48e322f90",
  )
}

///|
test "OBS 原生面：x-obs- 前缀进规范化头块，Authorization 用逗号后无空格那一形" {
  // 期望值来自那份自检过的独立参照实现，钉的是整串 Authorization：
  // 规范化、头前缀、scope、拼法四件事任何一处走偏都会当场红。
  let signed = obs_vec_sign(
    "GET",
    "/mldong/plain.txt",
    headers=[
      ("host", obs_native_host),
      ("x-obs-content-sha256", unsigned_payload),
      ("x-obs-date", obs_vec_ts),
    ],
    region=obs_native_region,
  )
  assert_eq(
    signed.canonical_request,
    "GET\n/mldong/plain.txt\n\nhost:" +
    obs_native_host +
    "\nx-obs-content-sha256:UNSIGNED-PAYLOAD\nx-obs-date:20261016T010203Z\n\nhost;x-obs-content-sha256;x-obs-date\nUNSIGNED-PAYLOAD",
  )
  assert_eq(
    signed.string_to_sign,
    "AWS4-HMAC-SHA256\n20261016T010203Z\n20261016/cn-south-1/s3/aws4_request\n20f5d675eb79247a11bd586455276eea4448224899c93f7757586f8bb1f2f6be",
  )
  assert_eq(
    signing_key_hex(obs_vec_sk, "20261016", obs_native_region),
    "cece8ebb1372428f255b8344a3e2ca63fef1c697927865eef4d6a7f3e7c148bf",
  )
  assert_eq(signed.signature, obs_native_signature)
  // 逗号后**没有空格**：AWS SDK 发的是带空格那一形，服务端两种都收（兼容腿已实测），
  // 但这里钉的是官方 Python SDK 的格式串——形状写歪时签名值照样对，所以必须单独钉。
  assert_eq(
    signed.authorization,
    "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261016/cn-south-1/s3/aws4_request,SignedHeaders=host;x-obs-content-sha256;x-obs-date,Signature=" +
    obs_native_signature,
  )
  assert_true(signed.authorization.contains(",SignedHeaders="))
  assert_true(!signed.authorization.contains(", SignedHeaders="))
  // 原生前缀下，头集合里出现的是 x-obs-date / x-obs-content-sha256，不是 x-amz-*
  assert_true(signed.signed_headers.contains("x-obs-date"))
  assert_true(signed.signed_headers.contains("x-obs-content-sha256"))
  assert_true(!signed.signed_headers.contains("x-amz-"))
}

///|
test "头前缀是可配的而不是写死的：Amz 那一档换一套头名，签名也跟着变" {
  let native = required_headers(obs_vec_ts)
  assert_eq(native[0].0, "x-obs-date")
  assert_eq(native[1].0, "x-obs-content-sha256")
  assert_eq(native[1].1, unsigned_payload)
  let compat = required_headers(obs_vec_ts, prefix=Amz)
  assert_eq(compat[0].0, "x-amz-date")
  assert_eq(compat[1].0, "x-amz-content-sha256")
  // 默认走原生
  assert_eq(default_header_prefix.text(), "x-obs-")
  let signed_compat = obs_vec_sign(
    "GET",
    "/mldong/plain.txt",
    headers=[
      ("host", obs_native_host),
      ("x-amz-content-sha256", unsigned_payload),
      ("x-amz-date", obs_vec_ts),
    ],
    region=obs_native_region,
  )
  // 头名进的是签名，前缀一换签名必变（这一格与上一条负向量互为对照）
  assert_true(signed_compat.signature != obs_native_signature)
}

///|
test "门面档：注入时刻 + 原生前缀补头，签出的结果与向量逐字相同" {
  // 走 Credentials 那条路（调用方只给 host，两个必带头由 SDK 补）。
  // 结果必须与上面手工拼头那一档一模一样，否则"发出去的头"与"签进去的头"就分家了。
  let credentials = Credentials::new(obs_vec_ak, obs_vec_sk)
  let signed = credentials.sign_at(
    obs_native_region,
    obs_vec_millis,
    RequestToSign::new("GET", "/mldong/plain.txt", headers=[
      ("host", obs_native_host),
    ]),
  )
  assert_eq(signed.timestamp, obs_vec_ts)
  assert_eq(signed.scope, "20261016/cn-south-1/s3/aws4_request")
  assert_eq(signed.signed_headers, "host;x-obs-content-sha256;x-obs-date")
  assert_eq(signed.signature, obs_native_signature)
}

///|
test "负向量：多签一个头，签名 hex 必须变（头集合真的进了签名，不是摆设）" {
  let signed = obs_vec_sign(
    "GET",
    "/mldong/plain.txt",
    headers=[
      ("host", obs_native_host),
      ("x-obs-acl", "private"),
      ("x-obs-content-sha256", unsigned_payload),
      ("x-obs-date", obs_vec_ts),
    ],
    region=obs_native_region,
  )
  assert_eq(
    signed.signed_headers,
    "host;x-obs-acl;x-obs-content-sha256;x-obs-date",
  )
  assert_eq(
    signed.signature,
    "6366840f312c488dcb5feadec8b7b869fcee7fcff608bca680e88a434331459c",
  )
  assert_true(signed.signature != obs_native_signature)
}

///|
test "负向量：少签一个头，签名 hex 也必须变" {
  let signed = obs_vec_sign(
    "GET",
    "/mldong/plain.txt",
    headers=[("host", obs_native_host), ("x-obs-date", obs_vec_ts)],
    region=obs_native_region,
  )
  assert_eq(signed.signed_headers, "host;x-obs-date")
  assert_eq(
    signed.signature,
    "cdb838d77d05cdc76183c26afec5d6169c8ddcfb3f3819feadc8d95eca0143b8",
  )
  assert_true(signed.signature != obs_native_signature)
}

///|
test "负向量：把 authorization 本身塞进待签头集合是直接拒，不是静默丢格" {
  let text = canonical_headers([
      ("host", obs_native_host),
      ("authorization", "AWS4-HMAC-SHA256 something"),
    ]).block catch {
      e => e.text()
    }
  assert_true(text.contains("obs bad-param"))
}

///|
test "与 AWS 的已知差别：同名查询参数按 dict 语义折叠（后进的赢）" {
  // AWS 向量 get_tricky_query 把 `x=2` 与 `x=1` 两档都签进去（期望签名 347a6ac9…）。
  // 官方 OBS Python SDK 的 `getCanonicalQueryString` 先 `canonMap[key] = value` 再排序，
  // 同名键只留最后一个 ⇒ 同一份输入在 OBS 形状下签不出 AWS 那个值。
  // 这一档不是"实现跟不上向量"，是两家的规范化形状不同，所以三条都钉：
  // 折叠后的规范化串、折叠后的期望签名（参照实现给），以及"绝不等于 AWS 那个签名"。
  let signed = obs_vec_sign(
    "GET",
    "/mldong/dir/a b+c%20d.txt",
    query=[
      ("prefix", "a/"),
      ("x", "2"),
      ("x", "1"),
      ("empty", ""),
      ("v", "%2B"),
    ],
    headers=[
      ("host", "minio.test:9000"),
      ("x-amz-content-sha256", obs_vec_empty_hash),
      ("x-amz-date", obs_vec_ts),
    ],
    payload_hash=obs_vec_empty_hash,
  )
  assert_eq(
    signed.canonical_request,
    "GET\n/mldong/dir/a b+c%20d.txt\nempty=&prefix=a%2F&v=%252B&x=1\nhost:minio.test:9000\nx-amz-content-sha256:" +
    obs_vec_empty_hash +
    "\nx-amz-date:20261016T010203Z\n\nhost;x-amz-content-sha256;x-amz-date\n" +
    obs_vec_empty_hash,
  )
  assert_eq(
    signed.signature,
    "8421f1a1623114b17d87540ce5f78c12ddbab9a5f97da4276f5c4ebaf949f490",
  )
  assert_true(
    signed.signature !=
    "347a6ac9fb637e72ebb8b557dcd3dd68db91976d9b4fdb9cfd312fb4762ee8e6",
  )
}

///|
test "编码与路径形状：键保留斜杠、值把斜杠编成 %2F、path 风格把桶名一起签进去" {
  assert_eq(
    encode_item("dir/sub file.txt", keep_slash=true),
    "dir/sub%20file.txt",
  )
  assert_eq(encode_item("dir/sub file.txt"), "dir%2Fsub%20file.txt")
  assert_eq(encode_item("a-._~b"), "a-._~b")
  assert_eq(encode_object_key("/bucket/dir/a b.txt"), "/bucket/dir/a%20b.txt")
  // 官方 SDK `getCanonicalURI`：path 风格前置 /bucket，两者皆空时是 /
  assert_eq(
    canonical_uri(bucket="bucket", key="dir/a b.txt"),
    "/bucket/dir/a%20b.txt",
  )
  assert_eq(
    canonical_uri(bucket="bucket", key="dir/a b.txt", path_style=false),
    "/dir/a%20b.txt",
  )
  assert_eq(canonical_uri(), "/")
  assert_eq(canonical_uri(bucket="bucket"), "/bucket")
  // 键里带斜杠时保持原样（`encode_item(k, '/')`），值里的斜杠编成 %2F
  assert_eq(
    canonical_query_string([("x/list", "dir/sub/")]),
    "x/list=dir%2Fsub%2F",
  )
  // 子资源参数也带等号（OSS 那一代是光键名）
  assert_eq(canonical_query_string([("acl", "")]), "acl=")
  assert_eq(canonical_query_string([]), "")
}

///|
test "日期串：注入的毫秒定出 longDate 与 shortDate，区名走 UTC" {
  let text = iso8601_basic(obs_vec_millis) catch { e => fail(e.text()) }
  assert_eq(text, "20261016T010203Z")
  let short = date_stamp(obs_vec_millis) catch { e => fail(e.text()) }
  assert_eq(short, "20261016")
  assert_eq(
    scope_of(short, obs_native_region),
    "20261016/cn-south-1/s3/aws4_request",
  )
}

///|
test "OBS 预签名档：五个 X-Amz 参数排序进签，签名最后追加且不入签" {
  let credentials = Credentials::new(obs_vec_ak, obs_vec_sk)
  let presigned = credentials.presign_at(
    obs_native_region,
    obs_vec_ts,
    600L,
    RequestToSign::new("GET", "/mldong/share.txt", headers=[
      ("host", obs_native_host),
    ]),
  )
  assert_eq(
    presigned.query,
    "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDEXAMPLE%2F20261016%2Fcn-south-1%2Fs3%2Faws4_request&X-Amz-Date=20261016T010203Z&X-Amz-Expires=600&X-Amz-SignedHeaders=host&X-Amz-Signature=dc12b8c34540dd27ab7a53cfcc9f3a064fbad0dce1c6b8862a4c92c9eae87ea6",
  )
  assert_eq(
    presigned.signature,
    "dc12b8c34540dd27ab7a53cfcc9f3a064fbad0dce1c6b8862a4c92c9eae87ea6",
  )
  assert_eq(presigned.signed_headers, "host")
  // 负载声明那一头在预签名这一档不进签名头集合（生成 URL 时正文未知）
  assert_true(!presigned.canonical_request.contains("x-obs-content-sha256"))
  assert_true(presigned.canonical_request.has_suffix("UNSIGNED-PAYLOAD"))
}

///|
test "本地照签得出的错输入一律拒：时刻格式、空凭据、有效期越界" {
  let bad_timestamp = sign_v4(
      obs_vec_ak,
      obs_vec_sk,
      obs_native_region,
      "20261016",
      RequestToSign::new("GET", "/"),
    ).signature catch {
      e => e.text()
    }
  assert_true(bad_timestamp.contains("timestamp must be YYYYMMDDTHHMMSSZ"))
  let empty_access = Credentials::new("", "sk").access_key() catch {
    _ => "rejected"
  }
  assert_eq(empty_access, "rejected")
  let empty_secret = Credentials::new("ak", "").access_key() catch {
    _ => "rejected"
  }
  assert_eq(empty_secret, "rejected")
  let too_long = presign_v4(
      obs_vec_ak,
      obs_vec_sk,
      obs_native_region,
      obs_vec_ts,
      604801L,
      RequestToSign::new("GET", "/"),
    ).signature catch {
      e => e.text()
    }
  assert_true(too_long.contains("presign validity"))
  let zero_expiry = presign_v4(
      obs_vec_ak,
      obs_vec_sk,
      obs_native_region,
      obs_vec_ts,
      0L,
      RequestToSign::new("GET", "/"),
    ).signature catch {
      e => e.text()
    }
  assert_true(zero_expiry.contains("presign validity"))
}

///|
test "凭据形状：密钥不派生任何可读接口，公开面只有 access_key" {
  // 这条线有先例：凭据打印出来就等于泄密。所以 `Credentials` 的字段既不加 `pub(all)`，
  // 也不派生 Show/Debug/ToJson——这里钉住"唯一的公开读数就是那半把键"。
  let credentials = Credentials::new(obs_vec_ak, obs_vec_sk)
  assert_eq(credentials.access_key(), obs_vec_ak)
  // `secret_key` 不出现在任何一串签名输出里（Authorization 只有 AK 与派生结果）
  let signed = credentials.sign_at(
    obs_native_region,
    obs_vec_millis,
    RequestToSign::new("GET", "/mldong/plain.txt", headers=[
      ("host", obs_native_host),
    ]),
  )
  assert_true(!signed.authorization.contains(obs_vec_sk))
  assert_true(!signed.string_to_sign.contains(obs_vec_sk))
  assert_true(!signed.canonical_request.contains(obs_vec_sk))
}
