///|
// scheme 这一格的**离线档**：不联网、不打真桶、不读任何凭据。
// 三档构造器（[Config::new]／[Config::from_region]／[Config::with_domain]）共用同一条对齐
// 纪律（[resolve_scheme]，它挂在 [split_origin] 那条前缀解析的路径末尾），所以这一档把
// 三档都过一遍：正向钉读数，负向钉文案。
//
// 真桶侧的事实只作背景、不在这里裁决：绑桶自定义域名 80 端口由 `Server: OBS` 亲口应答，
// 443 因桶侧没绑证书停在 TLS（那是 TLS 层的红，不是签名层）；区域端点这一格选 http 是给
// 代理／内网镜像／抓包用的，真桶默认仍该 https。

///|
/// 夹具凭据（纯假值，不是任何真密钥）。名字带 `scheme_` 前缀：同包测试文件共享顶层命名空间。
fn scheme_credentials() -> @auth.Credentials raise @error.ObsError {
  @auth.Credentials::new(
    "AKFORSHEMEONLY00000", "SKFORSHEMEONLY000000000000000000000000000000",
  )
}

///|
/// 三档共用同一个区域 id：读数里只该出现 scheme 这一个变量，不该混进第二把区域。
fn scheme_region() -> String {
  "cn-north-4"
}

///|
/// `Config::new` + 显式 `scheme~` 的读数臂：接受就报 scheme 与最终 URL，拒就报错误文案。
/// 判 raise 的姿势照 `domain_wbtest.mbt` 的 `domain_note`——返回 String 读数，负向那几档
/// 才能与正向写在同一条断言里（`assert_true` 在本版编译器里是 raise 函数，普通 `fn` 里别调）。
fn endpoint_scheme_note(endpoint : String, scheme : String) -> String {
  let creds = scheme_credentials() catch {
    err => return "raised: " + err.text()
  }
  let config = Config::new(endpoint, scheme_region(), creds, scheme~) catch {
    err => return "raised: " + err.text()
  }
  "accepted: " + config.scheme_of() + " " + config.url_of("b1", key="k.txt")
}

///|
/// 同一条纪律在 [Config::with_domain] 那一侧：冲突文案里的输入名应是 `domain`。
fn domain_scheme_note(domain : String, scheme : String) -> String {
  let creds = scheme_credentials() catch {
    err => return "raised: " + err.text()
  }
  let config = Config::with_domain(domain, scheme_region(), creds, scheme~) catch {
    err => return "raised: " + err.text()
  }
  "accepted: " + config.scheme_of() + " " + config.url_of("b1", key="k.txt")
}

///|
/// 同一条纪律在 [Config::from_region] 那一侧：它自己拼出来的基址天生没有前缀，
/// 所以 `scheme~` 在这里没有对手——给了就用、没给就 https，但坏值照样拦。
fn region_scheme_note(scheme : String) -> String {
  let creds = scheme_credentials() catch {
    err => return "raised: " + err.text()
  }
  let config = Config::from_region(scheme_region(), creds, scheme~) catch {
    err => return "raised: " + err.text()
  }
  "accepted: " + config.scheme_of() + " " + config.host_of("b1")
}

///|
/// 只给前缀、一个字没碰 `scheme~`：读数与加这一格之前逐字相同。
/// 这一条同时是"`scheme~` 的默认值填的是空串而不是 https"的证据——填 https 的话，
/// 下面那两条 `http://…` 会被判成"前缀 http + 默认 https"冲突而红，那是误伤合法输入。
test "scheme：只给前缀时照旧按前缀派生" {
  let creds = scheme_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let http_config = Config::new(
    "http://obs.cn-north-4.myhuaweicloud.com",
    scheme_region(),
    creds,
  ) catch {
    err => fail("new(http://…): " + err.text())
  }
  assert_eq(http_config.scheme_of(), "http")
  let https_config = Config::new(
    "https://obs.cn-north-4.myhuaweicloud.com",
    scheme_region(),
    creds,
  ) catch {
    err => fail("new(https://…): " + err.text())
  }
  assert_eq(https_config.scheme_of(), "https")
  // 域名档走的是同一条前缀派生，读数里桶名不进 host
  assert_eq(
    domain_scheme_note("http://cdn.example.com", ""),
    "accepted: http http://cdn.example.com/k.txt",
  )
  // 自建／本地端点带端口也一样：scheme 只改 URL 的头，不动 authority
  assert_eq(
    endpoint_scheme_note("http://obs.example.test:19000", ""),
    "accepted: http http://b1.obs.example.test:19000/k.txt",
  )
}

///|
/// 只给显式 `scheme~`（串不带前缀）：这一格就生效。域名档连 URL 一起钉——
/// 要的就是"`http://<域名>/"这一形出得来"；区域档另外钉"主机拼装一字未动"，
/// 免得有人把这一格读成"换了 scheme 也换个 host"。
test "scheme：只给显式值时三档都吃这一格" {
  let creds = scheme_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let region_config = Config::from_region(scheme_region(), creds, scheme="http") catch {
    err => fail("from_region(scheme=http): " + err.text())
  }
  assert_eq(region_config.scheme_of(), "http")
  assert_eq(
    region_config.url_of("b1", key="k.txt"),
    "http://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
  assert_eq(region_config.host_of("b1"), "b1.obs.cn-north-4.myhuaweicloud.com")
  let domain_config = Config::with_domain(
    "cdn.example.com",
    scheme_region(),
    creds,
    scheme="http",
  ) catch {
    err => fail("with_domain(scheme=http): " + err.text())
  }
  assert_eq(domain_config.url_of("whatever-bucket"), "http://cdn.example.com/")
  assert_eq(
    domain_config.url_of("whatever-bucket", key="a b/c+d.png"),
    "http://cdn.example.com/a%20b/c%2Bd.png",
  )
  // 端点档：串没前缀时显式值直接生效
  assert_eq(
    endpoint_scheme_note("obs.cn-north-4.myhuaweicloud.com", "http"),
    "accepted: http http://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
  // 区域档天生无前缀：给了就用、没给就是 https，三个读数各钉一次
  let host_read = "b1.obs.cn-north-4.myhuaweicloud.com"
  assert_eq(region_scheme_note("http"), "accepted: http " + host_read)
  assert_eq(region_scheme_note("https"), "accepted: https " + host_read)
  assert_eq(region_scheme_note(""), "accepted: https " + host_read)
}

///|
/// 串前缀与显式值说**同一个意思**：正常通过，不报冲突。
/// 这一条是防"冲突判据写反了变成一致也拒"——那种写法会把老老实实两处都写 https 的
/// 调用方拦在门外，而那种调用方是新加这一格后最自然的一批。
test "scheme：一致同给就收" {
  assert_eq(
    endpoint_scheme_note("https://obs.cn-north-4.myhuaweicloud.com", "https"),
    "accepted: https https://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
  assert_eq(
    endpoint_scheme_note("http://obs.cn-north-4.myhuaweicloud.com", "http"),
    "accepted: http http://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
  assert_eq(
    domain_scheme_note("http://cdn.example.com", "http"),
    "accepted: http http://cdn.example.com/k.txt",
  )
  // 一个纯尾斜杠照旧收（控制台那串常带），带尾斜杠的一致同给也过
  assert_eq(
    domain_scheme_note("https://cdn.example.com/", "https"),
    "accepted: https https://cdn.example.com/k.txt",
  )
}

///|
/// 冲突同给一律拒，且文案里**两处各是什么、还有那串的主机**都要看得见：
/// 只报一句"conflict"不带读数，排查的人只能回去猜是哪一格写错。
/// 域名档的错要说成 `domain` 不能说成 `endpoint`——同一条纪律，两个输入名。
test "scheme：串前缀与显式值不一致时拒，文案带输入名与主机" {
  let forward = endpoint_scheme_note(
    "https://obs.cn-north-4.myhuaweicloud.com", "http",
  )
  assert_true(forward.has_prefix("raised: obs bad-param:"))
  assert_true(forward.contains("endpoint"))
  assert_true(forward.contains("obs.cn-north-4.myhuaweicloud.com"))
  assert_true(forward.contains("https://"))
  assert_true(forward.contains("scheme=http"))
  // 反方向是同一条纪律（串 http 而显式给 https）
  let backward = endpoint_scheme_note("http://obs.example.test", "https")
  assert_true(backward.has_prefix("raised: obs bad-param:"))
  assert_true(backward.contains("endpoint"))
  assert_true(backward.contains("obs.example.test"))
  assert_true(backward.contains("http://"))
  assert_true(backward.contains("scheme=https"))
  // 域名档：输入名与主机都换成域名那一侧的读数
  let domain_clash = domain_scheme_note("https://cdn.example.com", "http")
  assert_true(domain_clash.has_prefix("raised: obs bad-param:"))
  assert_true(domain_clash.contains("domain"))
  assert_true(domain_clash.contains("cdn.example.com"))
  assert_true(domain_clash.contains("https://"))
  assert_true(domain_clash.contains("scheme=http"))
  assert_true(!domain_clash.contains("endpoint"))
}

///|
/// 坏值：`scheme~` 非空时只收 `http`／`https`，其余一律 BadParam 且文案带上给到的值。
/// 大小写不算同值——这一格进的是 URL 的头，不是给人看的标签。
test "scheme：坏值一律拒，文案带给到的值" {
  let ftp = endpoint_scheme_note("obs.cn-north-4.myhuaweicloud.com", "ftp")
  assert_true(ftp.has_prefix("raised: obs bad-param:"))
  assert_true(ftp.contains("scheme must be http or https, got: ftp"))
  assert_true(
    endpoint_scheme_note("obs.cn-north-4.myhuaweicloud.com", "HTTPS").contains(
      "scheme must be http or https, got: HTTPS",
    ),
  )
  // 三档共用同一条校验：域名档与区域档的坏值也在同一路径上被拦下
  assert_true(domain_scheme_note("cdn.example.com", "ftp").contains("got: ftp"))
  assert_true(
    region_scheme_note("ws").contains("scheme must be http or https, got: ws"),
  )
  // trim 只用于判值（与 endpoint/domain 串同一条规矩），文案里报的是给到的原串：
  // 带个尾空格的合法值收，带空格的坏值报出来仍带着那两个空格
  assert_eq(
    endpoint_scheme_note("obs.cn-north-4.myhuaweicloud.com", " http "),
    "accepted: http http://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
  assert_true(
    endpoint_scheme_note("obs.cn-north-4.myhuaweicloud.com", " ftp ").has_suffix(
      " ftp ",
    ),
  )
  // 串本身坏（带路径尾巴）时仍是原来那句文案，不被 scheme 那一格抢走
  assert_true(
    endpoint_scheme_note("https://obs.example.test/sneaky", "https").contains(
      "endpoint carries a path after the host",
    ),
  )
}

///|
/// 防改坏默认：三档都不给 `scheme~`、串也不带前缀 ⇒ 仍是 https。
/// 空串的含义是"调用方没显式指定"，所以它既不是"指定了一个空 scheme"，
/// 也不会盖掉串自带的前缀（最后那一条钉的就是这一点）。
test "scheme 回归：不给 scheme~ 也不给前缀时仍是 https" {
  let creds = scheme_credentials() catch {
    err => fail("credentials: " + err.text())
  }
  let bare = Config::new(
    "obs.cn-north-4.myhuaweicloud.com",
    scheme_region(),
    creds,
  ) catch {
    err => fail("new 无前缀又不给 scheme: " + err.text())
  }
  assert_eq(bare.scheme_of(), "https")
  assert_eq(bare.url_of("b1"), "https://b1.obs.cn-north-4.myhuaweicloud.com/")
  let bare_domain = Config::with_domain(
    "cdn.example.com",
    scheme_region(),
    creds,
  ) catch {
    err => fail("with_domain 无前缀又不给 scheme: " + err.text())
  }
  assert_eq(bare_domain.scheme_of(), "https")
  assert_eq(
    bare_domain.url_of("b1", key="k.txt"),
    "https://cdn.example.com/k.txt",
  )
  assert_eq(bare_domain.is_domain_style(), true)
  let bare_region = Config::from_region(scheme_region(), creds) catch {
    err => fail("from_region 不给 scheme: " + err.text())
  }
  assert_eq(bare_region.scheme_of(), "https")
  // 空串不等于"把前缀也清空"：串自带 http 前缀时前缀照旧生效
  assert_eq(
    endpoint_scheme_note("http://obs.cn-north-4.myhuaweicloud.com", ""),
    "accepted: http http://b1.obs.cn-north-4.myhuaweicloud.com/k.txt",
  )
}
