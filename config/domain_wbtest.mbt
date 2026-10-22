///|
// 自定义域名（已绑定到某一个桶）那一档的**离线档**：不联网、不打真桶、不读任何凭据。
// 域名档的三条承重事实来自真桶探针的读数（记录在 hub 的阶段 I 卡里，本文件不抄那些值）：
// · 域名本身已经指向那个桶，所以 host **逐字用**、绝不拼桶名前缀；
// · `桶名.域名` 那种拼法连 DNS 都不解析 ⇒ 拿虚主机那一套套到域名上是错的；
// · http 在真桶上是通的，https 卡在桶侧没绑证书（TLS 层，不是签名层）。
// 这一档只钉"本地能自证"的那一半：URL 形状、host 拼装、坏输入拒绝、签名面不受影响。

///|
/// 夹具凭据（纯假值，不是任何真密钥）。名字带 `domain_` 前缀：同包测试文件共享顶层命名空间。
fn domain_credentials() -> @auth.Credentials raise @error.ObsError {
  @auth.Credentials::new(
    "AKFORDOMAINONLY00000", "SKFORDOMAINONLY0000000000000000000000000000",
  )
}

///|
/// `Config::with_domain` 的读数臂：接受就报 `accepted`，拒就报错误文案。
/// 负向那几档要能与正向写在同一条断言里。
fn domain_note(domain : String, region : String) -> String {
  let creds = domain_credentials() catch {
    err => return "raised: " + err.text()
  }
  let config = Config::with_domain(domain, region, creds) catch {
    err => return "raised: " + err.text()
  }
  "accepted: " + config.scheme_of() + " " + config.host_of("b1")
}

///|
/// 同一条解析纪律在 [Config::new] 那一侧的读数臂：文案里的输入名仍是 `endpoint`。
fn endpoint_note(endpoint : String, region : String) -> String {
  let creds = domain_credentials() catch {
    err => return "raised: " + err.text()
  }
  let config = Config::new(endpoint, region, creds) catch {
    err => return "raised: " + err.text()
  }
  "accepted: " + config.scheme_of() + " " + config.host_of("b1")
}

///|
/// 取规范化请求的第二行（URI 那一行）。不整串比，是因为两档的 host 头本来就不同，
/// 整串比会红在**该不同**的那一格；这一条要钉的恰恰是"该相同"的这一行。
fn canonical_uri_line(canonical : String) -> String {
  match canonical.find("\n") {
    None => ""
    Some(head) => {
      let rest = canonical[head + 1:canonical.length()].to_owned()
      match rest.find("\n") {
        None => rest
        Some(tail) => rest[0:tail].to_owned()
      }
    }
  }
}

///|
test "域名档：scheme 跟着前缀走，URL 里不出现桶名前缀" {
  let creds = domain_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let http_config = Config::with_domain(
    "http://cdn.example.com", "cn-north-4", creds,
  ) catch {
    err => fail("with_domain(http://…): " + err.text())
  }
  assert_eq(http_config.scheme_of(), "http")
  assert_true(http_config.is_domain_style())
  assert_eq(
    http_config.url_of("whatever-bucket", key="a b/c+d.png"),
    "http://cdn.example.com/a%20b/c%2Bd.png",
  )
  // 空键是域名根，仍然只有一个斜杠，桶名不在任何一段里
  assert_eq(http_config.url_of(""), "http://cdn.example.com/")
  assert_eq(http_config.url_of("", key="k.txt"), "http://cdn.example.com/k.txt")
  // 不给前缀默认 https（与 Config::new 同一条派生规则）
  let bare = Config::with_domain("cdn.example.com", "cn-north-4", creds) catch {
    err => fail("with_domain(无前缀): " + err.text())
  }
  assert_eq(bare.scheme_of(), "https")
  assert_eq(bare.url_of("b1", key="k.txt"), "https://cdn.example.com/k.txt")
  // 一个纯尾斜杠照旧收（控制台那串常带），带尾巴的一律拒
  assert_eq(
    domain_note("https://cdn.example.com/", "cn-north-4"),
    "accepted: https cdn.example.com",
  )
  assert_eq(
    domain_note("http://cdn.example.com", "cn-north-4"),
    "accepted: http cdn.example.com",
  )
}

///|
/// 域名档下 host 只有一个来源：那个域名本身。空桶名与任何正常桶名都不得改变它
/// （真桶读数：`桶名.域名` DNS 不解析，拼上去当场建连失败）。
test "域名档：任何桶名都返回同一个逐字主机" {
  let creds = domain_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let config = Config::with_domain(
    "http://cdn.example.com", "cn-north-4", creds,
  ) catch {
    err => fail("with_domain: " + err.text())
  }
  for bucket in ["", "b1", "some-bucket-name", "cdn.example.com"] {
    assert_eq(config.host_of(bucket), "cdn.example.com")
  }
}

///|
/// 防改坏：虚主机档（[Config::new]／[Config::from_region]）的拼装一字未动。
test "虚主机档回归：仍然拼桶名前缀，空桶名仍是服务级主机" {
  let creds = domain_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let config = Config::new(
    "obs.cn-north-4.myhuaweicloud.com", "cn-north-4", creds,
  ) catch {
    err => fail("Config::new: " + err.text())
  }
  assert_true(!config.is_domain_style())
  assert_eq(config.host_of("b1"), "b1.obs.cn-north-4.myhuaweicloud.com")
  assert_eq(config.host_of(""), "obs.cn-north-4.myhuaweicloud.com")
  assert_eq(
    config.url_of("b1", key="k.txt"),
    "https://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
}

///|
/// 坏输入走的是与 [Config::new] 同一份解析纪律，只是文案里的输入名换成 `domain`：
/// `//` 之后 authority 为空、主机后还带路径尾巴（很可能藏着桶名）都响亮拒，不静默剥。
test "域名档负向：空 authority／带路径尾巴／空域名／空区域都拒" {
  let empty_authority = domain_note("http://", "cn-north-4")
  assert_true(empty_authority.has_prefix("raised"))
  assert_true(empty_authority.contains("domain host is not usable"))
  let sneaky_path = domain_note("https://x.com/sneaky", "cn-north-4")
  assert_true(sneaky_path.has_prefix("raised"))
  assert_true(sneaky_path.contains("domain carries a path after the host"))
  let empty_domain = domain_note("", "cn-north-4")
  assert_true(empty_domain.has_prefix("raised"))
  assert_true(empty_domain.contains("domain is empty"))
  // 区域照旧必填：它进的是签名 scope，与寻址档位无关
  let no_region = domain_note("cdn.example.com", "")
  assert_true(no_region.has_prefix("raised"))
  assert_true(no_region.contains("region is empty"))
  // Config::new 那一份纪律的文案一字未改（这一条钉的是重构没把老文案带跑）
  assert_true(
    endpoint_note("https://x.com/sneaky", "cn-north-4").contains(
      "endpoint carries a path after the host",
    ),
  )
  assert_true(endpoint_note("", "cn-north-4").contains("endpoint is empty"))
  assert_true(endpoint_note("bad host", "cn-north-4").contains("endpoint host"))
}

///|
/// 签名面不因档位而变：规范化路径里本来就不含桶名，所以同一把键在域名档与虚主机档
/// 算出的 `canonical_request` 第二行必须逐字相同（真桶实测：域名档带空桶名 put/stat/
/// presign 全过，签名认的就是这一行）。
test "签名面：两档的 canonical_request 第二行相同" {
  let creds = domain_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let domain_config = Config::with_domain(
    "http://cdn.example.com", "cn-north-4", creds,
  ) catch {
    err => fail("with_domain: " + err.text())
  }
  let vhost_config = Config::new(
    "obs.cn-north-4.myhuaweicloud.com", "cn-north-4", creds,
  ) catch {
    err => fail("Config::new: " + err.text())
  }
  let domain_uri = domain_config.canonical_uri_of("b1", key="a b/c+d.png")
  let vhost_uri = vhost_config.canonical_uri_of("b1", key="a b/c+d.png")
  assert_eq(domain_uri, "/a%20b/c%2Bd.png")
  assert_eq(domain_uri, vhost_uri)
  let domain_request = @auth.RequestToSign::new("PUT", domain_uri, headers=[
    ("host", domain_config.host_of("b1")),
  ])
  let vhost_request = @auth.RequestToSign::new("PUT", vhost_uri, headers=[
    ("host", vhost_config.host_of("b1")),
  ])
  let domain_canonical = @auth.canonical_request(domain_request) catch {
    err => fail("域名档规范化请求: " + err.text())
  }
  let vhost_canonical = @auth.canonical_request(vhost_request) catch {
    err => fail("虚主机档规范化请求: " + err.text())
  }
  assert_eq(
    canonical_uri_line(domain_canonical),
    canonical_uri_line(vhost_canonical),
  )
  assert_eq(canonical_uri_line(domain_canonical), "/a%20b/c%2Bd.png")
  // 两档 host 本来就该不同（这正是这一档存在的理由），所以整串必须不等
  assert_true(domain_canonical != vhost_canonical)
  assert_true(domain_canonical.contains("host:cdn.example.com"))
  assert_true(
    vhost_canonical.contains("host:b1.obs.cn-north-4.myhuaweicloud.com"),
  )
}
