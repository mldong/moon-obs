///|
// 离线形状档（白盒：只在这包里能拿到的私有守卫也纳入）。
// 网络一律不碰——这一档在没凭据的机器上也必须跑绿，否则它就分不清"实现错"与"没凭据"。
//
// 三条实测项（`list-type=2`／分片下限／`x-obs-acl` 取值面）不在这里裁决，
// 它们只由 `live_test.mbt` 在真桶上量；这里钉的是签名与装配层能自证的部分。

///|
fn shape_credentials() -> @auth.Credentials raise @error.ObsError {
  @auth.Credentials::new(
    "AKFORSHAPEONLY000000", "SKFORSHAPEONLY0000000000000000000000000000",
  )
}

///|
/// `Config::new` 的读数臂：接受就报解析结果，拒就报错误文案。
/// 拿 String 而不是结构体出来，是为了让负向那几档能与正向写在同一条断言里。
fn config_note(endpoint : String, region : String) -> String {
  let creds = shape_credentials() catch {
    err => return "raised: " + err.text()
  }
  let config = @config.Config::new(endpoint, region, creds) catch {
    err => return "raised: " + err.text()
  }
  "accepted: " + config.scheme_of() + " " + config.host_of("b")
}

///|
/// 同一招用在两个 Unit 守卫上：过了报 `ok`，拒了报错误文案。
fn reject_note(extra : Array[(String, String)]) -> String {
  let timestamp = "20261019T010203Z"
  let required = @auth.required_headers(timestamp, prefix=signed_prefix)
  reject_reserved(extra, required) catch {
    err => return err.text()
  }
  "ok"
}

///|
fn bind_note(signed : String) -> String {
  let timestamp = "20261019T010203Z"
  let required = @auth.required_headers(timestamp, prefix=signed_prefix)
  bind_signed_to_wire(signed, required, [("content-type", "text/plain")]) catch {
    err => return err.text()
  }
  "ok"
}

///|
test "端点派生：原生基址与虚主机，键按 UTF-8 百分号编码" {
  let config = @config.Config::from_region("cn-south-1", shape_credentials()) catch {
    err => fail("from_region: " + err.text())
  }
  assert_eq(
    @config.native_endpoint_host("cn-south-1"),
    "obs.cn-south-1.myhuaweicloud.com",
  )
  assert_eq(
    config.host_of("examplebucket"),
    "examplebucket.obs.cn-south-1.myhuaweicloud.com",
  )
  // 服务级（列桶）不带桶前缀
  assert_eq(config.host_of(""), "obs.cn-south-1.myhuaweicloud.com")
  assert_eq(
    config.url_of("examplebucket", key="dir/中文 键.txt"),
    "https://examplebucket.obs.cn-south-1.myhuaweicloud.com/dir/%E4%B8%AD%E6%96%87%20%E9%94%AE.txt",
  )
  assert_eq(
    config.url_of("examplebucket"),
    "https://examplebucket.obs.cn-south-1.myhuaweicloud.com/",
  )
  assert_eq(
    config.url_of("", key="k.txt"),
    "https://obs.cn-south-1.myhuaweicloud.com/k.txt",
  )
}

///|
/// 虚主机寻址下**桶名不进签名路径**——这一条与 `moon-oss` 正相反（那边实测要把
/// `/<bucket>` 签进去），照抄就会当场 `SignatureDoesNotMatch`。
test "规范化路径只到键为止：桶名不出现在里面" {
  let config = @config.Config::from_region("cn-south-1", shape_credentials()) catch {
    err => fail("from_region: " + err.text())
  }
  assert_eq(config.canonical_uri_of("examplebucket", key=""), "/")
  assert_eq(config.canonical_uri_of("", key=""), "/")
  assert_eq(
    config.canonical_uri_of("examplebucket", key="a/b c.txt"),
    "/a/b%20c.txt",
  )
  let with_bucket = config.canonical_uri_of("examplebucket", key="k")
  assert_true(!with_bucket.contains("examplebucket"))
}

///|
/// path 风格那一档必须是**响亮拒绝**，而不是"给了一个大概能用的 URL"。
/// 兼容面实测读数：path 风格的对象请求回 403 `VirtualHostDomainRequired`（带正文）。
test "path 风格：调用它就拒，拒的文案带上实测的那个码" {
  let config = @config.Config::from_region("cn-south-1", shape_credentials()) catch {
    err => fail("from_region: " + err.text())
  }
  let note = config.path_style_url("examplebucket", key="k.txt") catch {
    err => err.text()
  }
  assert_true(note.has_prefix("obs bad-param:"))
  assert_true(note.contains("VirtualHostDomainRequired"))
  assert_true(note.contains("examplebucket/k.txt"))
  let service_note = config.path_style_url("") catch { err => err.text() }
  assert_true(service_note.contains("the service root"))
}

///|
/// endpoint 里粘了路径尾巴／空主机／空区域的一律拒——那类输入十有八九是
/// 控制台"访问域名"整串粘错。
test "endpoint 解析：带 scheme 要剥、空主机与空区域要拒" {
  assert_eq(
    config_note("https://obs.cn-south-1.myhuaweicloud.com", "cn-south-1"),
    "accepted: https b.obs.cn-south-1.myhuaweicloud.com",
  )
  assert_eq(
    config_note("obs.cn-south-1.myhuaweicloud.com", "cn-south-1"),
    "accepted: https b.obs.cn-south-1.myhuaweicloud.com",
  )
  // 自建／本地端点可以带端口：主机名整体保留，签名用的 host 与 URL 的 authority 同源
  assert_eq(
    config_note("http://obs.example.test:19000", "cn-south-1"),
    "accepted: http b.obs.example.test:19000",
  )
  assert_true(
    config_note("https://obs.example.test/", "cn-south-1").has_prefix(
      "accepted",
    ),
  )
  // 斜杠后还有东西（十有八九是把桶名一起粘了过来）一律拒，不静默剥
  assert_true(
    config_note("https://obs.example.test/somebucket", "cn-south-1").has_prefix(
      "raised",
    ),
  )
  assert_true(config_note("bad host", "cn-south-1").has_prefix("raised"))
  assert_true(config_note("https://", "cn-south-1").has_prefix("raised"))
  assert_true(config_note("", "cn-south-1").has_prefix("raised"))
  assert_true(
    config_note("obs.cn-south-1.myhuaweicloud.com", "").has_prefix("raised"),
  )
}

///|
/// `host` 入签、`x-obs-date`／`x-obs-content-sha256` 入签、调用方给的头入签——
/// SignedHeaders 必须正好是这一份。这一条是 OBS `传进来的每个头都签`（无 allowlist）
/// 的正面读数：少签一个头就是一条看不出根因的 403。
test "签名头集：host 与两头固定件与调用方的头，一个不多一个不少" {
  let required = @auth.required_headers(
    "20261019T010203Z",
    prefix=signed_prefix,
  )
  assert_eq(required[0].0, "x-amz-date")
  assert_eq(required[1].0, "x-amz-content-sha256")
  assert_eq(required[1].1, @auth.unsigned_payload)
  let extra : Array[(String, String)] = [
    ("Content-Type", "text/plain"),
    ("x-amz-meta-tool", "moon-obs"),
  ]
  let signature = shape_credentials().sign_at(
    "cn-south-1",
    1760000000000L,
    @auth.RequestToSign::{
      verb: "PUT",
      canonical_uri: "/shape.txt",
      query: [],
      headers: [("host", "b.obs.cn-south-1.myhuaweicloud.com")] + extra,
      payload_hash: @auth.unsigned_payload,
    },
    header_prefix=signed_prefix,
  ) catch {
    err => fail("sign_at: " + err.text())
  }
  assert_eq(
    signature.signed_headers,
    "content-type;host;x-amz-content-sha256;x-amz-date;x-amz-meta-tool",
  )
  // 与装配层那条**独立实现**的对拍：同一份头名，两边算出来的串必须一致
  let names : Array[String] = ["host", "x-amz-meta-tool", "content-type"]
  for pair in required {
    names.push(pair.0.to_lower())
  }
  assert_eq(ascii_join(names), signature.signed_headers)
}

///|
/// Authorization 的 OBS 拼法：逗号后**没有空格**。签名值对、形状歪，向量测试照样绿，
/// 所以这一格只能单独钉（隔壁 `moon-s3` 发的是 AWS 那串带空格的形状）。
test "Authorization 形状：OBS 的逗号后无空格、scope 服务名是 s3" {
  let signature = shape_credentials().sign_at("cn-south-1", 1760000000000L, @auth.RequestToSign::{
    verb: "GET",
    canonical_uri: "/",
    query: [],
    headers: [("host", "obs.cn-south-1.myhuaweicloud.com")],
    payload_hash: @auth.unsigned_payload,
  }) catch {
    err => fail("sign_at: " + err.text())
  }
  assert_true(
    signature.authorization.has_prefix("AWS4-HMAC-SHA256 Credential="),
  )
  assert_true(!signature.authorization.contains(", "))
  assert_true(signature.authorization.contains(",SignedHeaders=host"))
  assert_true(signature.authorization.contains(",Signature="))
  let stamp = @auth.date_stamp(1760000000000L) catch {
    err => fail("date_stamp: " + err.text())
  }
  assert_true(signature.scope.has_prefix(stamp))
  assert_true(signature.scope.contains("/cn-south-1/s3/aws4_request"))
}

///|
/// 空值参数在 OBS 的规范化查询串里**带等号**（`acl=`、`uploads=`）。
/// OSS 那边是无值只写键名——装配层把 `("acl","")` 交给签名件时就该看到这个形状。
test "查询串形状：空值带等号、按原始键排序" {
  assert_eq(@auth.canonical_query_string([("acl", "")]), "acl=")
  // 键保 `/`、值不保：`encode_item(k, '/')` 与 `encode_item(v, '')` 两档不同，
  // 所以 `prefix=dir/` 在规范化串里是 `dir%2F`——这一格由签名件定，装配层照它发线。
  assert_eq(
    @auth.canonical_query_string([
      ("uploads", ""),
      ("max-keys", "5"),
      ("prefix", "dir/"),
    ]),
    "max-keys=5&prefix=dir%2F&uploads=",
  )
}

///|
/// 装配层的两处守卫：调用方不许自带 host／authorization／两个必带头，
/// 且"签进去的头名"与"发到线上的头名"分叉时当场拒（而不是发出去等一条 403）。
test "守卫：自带保留头要拒，签与线分叉要拒" {
  assert_true(
    reject_note([("host", "evil.example")]).contains("must not be passed in"),
  )
  assert_true(reject_note([("x-amz-date", "wrong")]).contains("x-amz-date"))
  assert_true(
    reject_note([("x-amz-content-sha256", "wrong")]).contains(
      "x-amz-content-sha256",
    ),
  )
  assert_true(
    reject_note([("authorization", "x")]).contains("must not be passed in"),
  )
  assert_eq(reject_note([("content-type", "text/plain")]), "ok")
  assert_true(bind_note("host;x-obs-date").contains("diverged"))
  assert_eq(
    bind_note("content-type;host;x-amz-content-sha256;x-amz-date"),
    "ok",
  )
}

///|
/// 头名只有一个出处：原生面 `x-obs-*`。兼容面的 `x-amz-*` 不在本包的承诺面里，
/// 所以这里钉的是"装配层各处拿到的名字都来自同一个前缀开关"。
test "头名前缀：acl／meta／copy-source／request-id 同出一处" {
  assert_eq(acl_header_name(), "x-amz-acl")
  assert_eq(meta_header_prefix(), "x-amz-meta-")
  assert_eq(copy_source_header_name(), "x-amz-copy-source")
  assert_eq(request_id_header(), "x-amz-request-id")
  assert_eq(signed_prefix.date_header(), "x-amz-date")
  assert_eq(signed_prefix.content_sha256_header(), "x-amz-content-sha256")
  assert_eq(signed_prefix.security_token_header(), "x-amz-security-token")
}

///|
/// 真桶实测定下来的口径：**V4 这一族在 OBS 原生端点只披 `x-amz-*`**。
/// 换成 `x-obs-date`／`x-obs-content-sha256` 后 GET 与 PUT 都回
/// `400 InvalidArgument`，正文文案 `Missing required header for this request:
/// x-amz-content-sha256`；只带 `x-obs-acl` 的 `PUT /key?acl=` 回 `400 MissingSecurityHeader`。
/// 参照实现同一处对得上：官方 SDK 的 `V4Authentication` 只在 `signature == 'v4'` 装配，
/// 那一档的适配器 `is_obs` 为假 ⇒ 前缀恒为 `x-amz-`；`x-obs-*` 属于 V2/`OBS` 那条线。
/// 这一档钉的是"装配层不能悄悄退回 `x-obs-*`"——退回就整条红，而红点是 400 不是 403。
test "头名族口径：V4 走 x-amz-，x-obs- 那一族不在本包的 V4 线里" {
  assert_eq(signed_prefix.text(), "x-amz-")
  assert_eq(@auth.default_header_prefix.text(), "x-obs-")
  // 两个前缀的头名不能混着发：混了就是上面那两个 400
  assert_true(acl_header_name() == "x-amz-acl")
  assert_true(@auth.HeaderPrefix::Obs.acl_header() == "x-obs-acl")
}

///|
/// 命名空间与属性会把"整串匹配"的解析器打成"字段不存在"。
/// 这份样本按 OBS 回体的真实形状写（根元素带默认命名空间、`Grantee` 带 `xsi:type`），
/// 账号标识与组 URI 都是假值——要验的是**解析**，不是任何真桶。
let acl_fixture : String = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
  "<AccessControlPolicy xmlns=\"http://obs.myhwclouds.com/doc/2015-06-30/\">" +
  "<Owner><ID>0000000000000000000000000000000000000000000000000000000000000000</ID>" +
  "<DisplayName>fake-owner</DisplayName></Owner><AccessGrants>" +
  "<Grant><Grantee xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:type=\"Group\">" +
  "<URI>http://acs.myhwclouds.com/groups/all_users</URI></Grantee>" +
  "<Permission>READ</Permission></Grant>" +
  "<Grant><Grantee xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:type=\"CanonicalUser\">" +
  "<ID>0000000000000000000000000000000000000000000000000000000000000000</ID>" +
  "<DisplayName>fake-owner</DisplayName></Grantee>" +
  "<Permission>FULL_CONTROL</Permission></Grant>" +
  "</AccessGrants></AccessControlPolicy>"

///|
fn must_element(
  body : String,
  tag : String,
) -> XmlElement raise @error.ObsError {
  match xml_element(body, tag) {
    None => raise @error.BadParam("element not found by local name: " + tag)
    Some(elem) => elem
  }
}

///|
test "XML：带命名空间与属性的 grant 回体要按局部名读出来" {
  let policy = must_element(acl_fixture, "AccessControlPolicy") catch {
    err => fail("fixture: " + err.text())
  }
  assert_eq(
    or_empty(policy.ns_decl("xmlns")),
    "http://obs.myhwclouds.com/doc/2015-06-30/",
  )
  // 命名空间声明不许冒充业务属性：`attr("xmlns")` 读不到，专读件才读得到
  let grantee_type = first_grantee_type() catch {
    err => fail("fixture: " + err.text())
  }
  assert_eq(grantee_type, "Group")
  let grants = xml_elements(acl_fixture, "Grant")
  assert_eq(grants.length(), 2)
  assert_eq(
    or_empty(xml_first(grants[0].content, "URI")),
    "http://acs.myhwclouds.com/groups/all_users",
  )
  assert_eq(or_empty(xml_first(grants[0].content, "Permission")), "READ")
  let second = must_element(grants[1].content, "Grantee") catch {
    err => fail("fixture: " + err.text())
  }
  assert_eq(or_empty(second.attr("type")), "CanonicalUser")
  assert_eq(
    or_empty(xml_first(grants[1].content, "Permission")),
    "FULL_CONTROL",
  )
  let names = xml_element_names(acl_fixture)
  assert_true(has_name(names, "AccessControlPolicy"))
  assert_true(has_name(names, "AccessGrants"))
  assert_true(has_name(names, "Grantee"))
  assert_true(has_name(names, "URI"))
}

///|
/// 抽出来单写一条：`Grantee` 的 `xsi:type` 必须读成 `Group`，
/// 而命名空间声明 `xmlns:xsi` 不许抢先命中 `attr("xsi")`／`attr("type")` 的误读。
fn first_grantee_type() -> String raise @error.ObsError {
  let grants = xml_elements(acl_fixture, "Grant")
  or_empty(must_element(grants[0].content, "Grantee").attr("type"))
}

///|
/// 带前缀的元素名、实体、自闭合、缺失四种形状各钉一条。
/// "读不到"必须是 `None`，不能是空串——否则"这一格服务端没给"会被读成"服务端给了空"。
test "XML：前缀名／实体／自闭合／缺失四种形状" {
  let body = "<obs:ListBucketResult xmlns:obs=\"urn:obs\">" +
    "<obs:Contents><Key>a&amp;b&lt;c</Key><Size>3</Size></obs:Contents>" +
    "<obs:Contents><Key>plain</Key><Size>7</Size><Owner><ID/></Owner></obs:Contents>" +
    "</obs:ListBucketResult>"
  let rows = xml_sections(body, "Contents")
  assert_eq(rows.length(), 2)
  assert_eq(or_empty(xml_first(rows[0], "Key")), "a&b<c")
  assert_eq(or_empty(xml_first(rows[1], "Size")), "7")
  let empty = must_element(rows[1], "ID") catch {
    err => fail("fixture: " + err.text())
  }
  assert_true(empty.self_closing)
  assert_eq(empty.content, "")
  assert_true(xml_element(body, "NoSuchElement") is None)
  assert_eq(xml_all(body, "NoSuchElement").length(), 0)
  assert_eq(xml_error_code(body), "")
  assert_eq(
    xml_error_code("<Error><Code>SignatureDoesNotMatch</Code></Error>"),
    "SignatureDoesNotMatch",
  )
}

///|
/// 预签名的形状读数（离线可证的那一半）：`host` 入签、参数名是 `X-Amz-*` 那一套、
/// 负载声明 `UNSIGNED-PAYLOAD`。真桶上"能不能打开"由 live 档量。
test "预签名 URL：参数名 X-Amz- 且 SignedHeaders=host" {
  let config = @config.Config::from_region("cn-south-1", shape_credentials()) catch {
    err => fail("from_region: " + err.text())
  }
  let client = Client::new(config, @transport.AsyncHttpTransport::new())
  let url = client.presigned_get_url("examplebucket", "k.txt", expires_sec=120L) catch {
    err => fail("presigned_get_url: " + err.text())
  }
  assert_true(
    url.has_prefix(
      "https://examplebucket.obs.cn-south-1.myhuaweicloud.com/k.txt?",
    ),
  )
  assert_true(url.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
  assert_true(url.contains("X-Amz-SignedHeaders=host"))
  assert_true(url.contains("X-Amz-Expires=120"))
  assert_true(url.contains("X-Amz-Signature="))
  assert_true(!url.contains("x-obs-"))
  // 凭据进参数时整串按"值"编码：`/` 变 `%2F`（与 OSS 那家把 credential 原样拼的形状不同）
  assert_true(url.contains("X-Amz-Credential=AKFORSHAPEONLY000000%2F"))
  assert_true(url.contains("%2Fcn-south-1%2Fs3%2Faws4_request"))
}
