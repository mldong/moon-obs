///|
/// OBS 的区域、凭据与端点派生。
///
/// 一条实测事实决定了这里的形状：**OBS 的原生端点只有 virtual-hosted 寻址**。同一条对象
/// 请求走 path 风格（`https://obs.<region>.myhuaweicloud.com/<bucket>/<key>`）一律回
/// 403 `VirtualHostDomainRequired`（带正文，非空响应），本卡 §1 已实测。
/// 所以这里**不提供寻址风格开关**——没有可选项的东西做成配置，接入方会以为关掉它就能绕过；
/// 只留一条 [path_style_url]，谁调它就响亮拒绝。
///
/// 原生端点基址是 `obs.<region>.myhuaweicloud.com`，虚主机是 `<bucket>.<基址>`。
/// AWS 那套 `s3.<region>.…` 形态在本机连 DNS 都解析不到，别拿它当默认值。
///
/// 另有**一档不属于"path 风格"**的寻址：桶自己绑定的自定义域名（[Config::with_domain]）。
/// 那一档里域名已经指向这个桶，host 逐字用、**绝不拼桶名前缀**（真桶实测：`<桶名>.<域名>`
/// 连 DNS 都不解析，把虚主机那一套搬过来当场建连失败）。
/// 区域照旧必填：它进的是签名 scope，与寻址档位无关。
///
/// ## scheme 从哪来
///
/// 有两种写法，**都合法**：把 scheme 藏在串的前缀里（`http://…`／`https://…`），
/// 或给构造器显式的 `scheme~`。但**二者只能表达一个意思**——串是 `https://x` 而
/// `scheme~` 给 `http` 会当场 `BadParam`，既不"后者覆盖前者"也不"后者被前者静默忽略"：
/// 那种静默会让线上真跑的那条腿与读代码的人以为的那条不是一根。两处都不给时是 `https`。
///
/// `scheme~` 的默认值是**空串**而不是 `"https"`，这一格是刻意的：空串的含义是
/// "调用方没显式指定"，于是 `Config::new("http://obs.x.com", …)` 这种自带前缀的合法写法
/// 不会被误判成冲突（默认值若填 https，"前缀 http + 默认 https"就成了自相矛盾）。
///
/// "区域端点也能选 http"这一格是给**代理／内网镜像／抓包**用的，真桶的默认仍该 https。
/// 自定义域名那一档的实测与区域端点不同：绑桶域名 80 端口由 `Server: OBS` 亲口应答
/// （对象族与同桶复制全量过），443 因桶侧没绑证书停在 TLS——那一档的 http 是真通的。

///|
pub(all) struct Config {
  /// "https" 或 "http"。来源只有两条：串自带的前缀，或构造器显式的 `scheme~`
  /// （二者只能说同一个意思，见文件头）；两处都没给就是 https。
  /// 真端点只该用 https；自定义域名那一档按实测允许 http。
  scheme : String
  /// 形如 `obs.cn-south-1.myhuaweicloud.com`，不带 scheme；
  /// 虚主机档它是**不含桶名的基址**，域名档它就是那个域名本身
  endpoint_host : String
  /// 签名 scope 用的区域 id，如 `cn-south-1`
  region : String
  credentials : @auth.Credentials
  /// 真 ⇒ host 逐字用 [endpoint_host]，不给桶名前缀（自定义域名那一档）。
  /// 私有：这一格必须由构造器定，让调用方手改就等于造出"域名档却拼桶名"那种没人验证过的形状。
  priv domain_style : Bool
}

///|
/// OBS 服务端的基址（不含桶名）。纯函数，签名件与测试都要拿同一份派生规则。
pub fn native_endpoint_host(region : String) -> String {
  "obs." + region + ".myhuaweicloud.com"
}

///|
/// 只给区域就能装配：基址按 [native_endpoint_host] 派生。
///
/// - `scheme~` 空串（默认）⇒ https；给了就照它来。这一档**不存在冲突**：
///   自己拼出来的基址天生没有前缀，所以显式值没有对手（前缀那一格是空的），
///   校验仍与 [Config::new] 同一条（只收 `http`／`https`，别的一律 `BadParam`）。
/// - 想固定用 https 就别给这一格：`scheme~="https"` 与不给在这一档读数相同。
pub fn Config::from_region(
  region : String,
  credentials : @auth.Credentials,
  scheme~ : String = "",
) -> Config raise @error.ObsError {
  if region.is_empty() {
    raise @error.BadParam("region is empty")
  }
  Config::new(native_endpoint_host(region), region, credentials, scheme~)
}

///|
/// 把"调用方显式给的 scheme"与"串前缀派生出的 scheme"对齐成一条读数，
/// 三条构造器共用这一份纪律（见 [split_origin]，前缀解析就在它里面）。
///
/// - `explicit` trim 后是空串 ⇒ 完全保持既有行为：有前缀跟前缀，没前缀就是 `https`；
/// - 非空 ⇒ 只收 `http`／`https`，其余（`ftp`、`HTTPS` 这种大小写不算）一律 `BadParam`，
///   文案里报**给到的原串**（含空格），不是 trim 后的那一份；
/// - `prefix~` 用 `String?` 而不是直接给 `"https"`，为的是区分**两件不同的事**：
///   `None`＝串根本没带前缀（此时显式值直接生效），`Some(s)`＝串自带 `s://`
///   （此时两边必须同值）。把 `None` 也读成 https，就会把
///   [Config::from_region]（无前缀基址）+ `scheme="http"` 误判成冲突，那是误伤合法输入。
fn resolve_scheme(
  explicit : String,
  prefix_scheme : String?,
  label~ : String,
  host~ : String,
) -> String raise @error.ObsError {
  // 与 endpoint/domain 串同一条规矩：先 trim 再判。这一格常从环境变量里来，
  // 带个尾空格不该读成"给了一个非法 scheme"。
  let given = explicit.trim().to_owned()
  if given.is_empty() {
    match prefix_scheme {
      None => "https"
      Some(s) => s
    }
  } else if given != "http" && given != "https" {
    raise @error.BadParam("scheme must be http or https, got: " + explicit)
  } else {
    match prefix_scheme {
      None => given
      Some(s) =>
        if s == given {
          given
        } else {
          raise @error.BadParam(
            label +
            " " +
            host +
            " carries the " +
            s +
            ":// prefix but scheme=" +
            explicit +
            " was given: the two are one setting, they must say the same thing",
          )
        }
    }
  }
}

///|
/// 两条构造器共用的那一份解析纪律：scheme 从前缀派生（没给前缀就是 `https`），
/// `//` 之后 authority 为空、或主机后还带路径尾巴的直接拒——那类输入十有八九是把
/// 控制台"访问域名"整串（含桶名或斜杠）粘了过来。返回 `(scheme, host)`。
/// 文案里的 `label` 由调用方给（`endpoint`／`domain`）：域名档的错不该说成端点档的错。
///
/// `scheme~` 是调用方显式给的那一格，解析出的前缀与它在 [resolve_scheme] 里对齐：
/// 空串（默认）＝没显式指定，一切照旧按前缀派生。
fn split_origin(
  input : String,
  label : String,
  scheme~ : String = "",
) -> (String, String) raise @error.ObsError {
  let trimmed = input.trim().to_owned()
  if trimmed.is_empty() {
    raise @error.BadParam(label + " is empty")
  }
  // 前缀派生的结果记成 `String?`：`None` 是"串没带前缀"，`Some(_)` 是"串自带这一格"。
  // 这两件事在 resolve_scheme 里必须分开判，混一起就分不清"默认"与"冲突"了。
  let prefix_scheme = if trimmed.has_prefix("https://") {
    Some("https")
  } else if trimmed.has_prefix("http://") {
    Some("http")
  } else {
    None
  }
  let rest = match trimmed.find("://") {
    None => trimmed
    Some(cut) => trimmed[cut + 3:trimmed.length()].to_owned()
  }
  let host = match rest.find("/") {
    None => rest
    Some(cut) => {
      // 允许一个纯尾斜杠（控制台域名常带），但斜杠后还有东西就是"把访问域名整串粘了过来"，
      // 里面很可能藏着桶名——那种输入静默剥掉会让请求打到错误的桶，所以响亮拒。
      let tail = rest[cut + 1:rest.length()].to_owned()
      if !tail.is_empty() {
        raise @error.BadParam(label + " carries a path after the host: " + rest)
      }
      rest[0:cut].to_owned()
    }
  }
  if host.is_empty() || host.contains(" ") {
    raise @error.BadParam(label + " host is not usable: " + host)
  }
  (resolve_scheme(scheme, prefix_scheme, label~, host~), host)
}

///|
/// `endpoint` 接受带或不带 scheme 两种写法；带 `//` 之后 authority 为空、或带路径尾巴的
/// 直接拒——那类输入十有八九是把控制台"访问域名"整串（含桶名或斜杠）粘了过来。
///
/// - `scheme~` 与串前缀**两种写法都合法，但二者只能表达一个意思**：串是 `https://x`
///   而这里给 `http` 一律 `BadParam`（文案把两处各是什么、以及那个主机一起报出来）。
///   默认值是空串，含义是"调用方没显式指定"——**不是** `"https"`：填 https 会把
///   `Config::new("http://obs.x.com", …)` 这种自带前缀的合法输入误伤成冲突；
/// - 给了非 `http`／`https` 的值（`ftp`、带空格、大小写不对的 `HTTPS`）也 `BadParam`；
/// - `scheme~="http"` 打在区域端点上是给**代理／内网镜像／抓包**用的，真桶默认仍该 https。
pub fn Config::new(
  endpoint : String,
  region : String,
  credentials : @auth.Credentials,
  scheme~ : String = "",
) -> Config raise @error.ObsError {
  if region.is_empty() {
    raise @error.BadParam("region is empty")
  }
  let (scheme, host) = split_origin(endpoint, "endpoint", scheme~)
  Config::{
    scheme,
    endpoint_host: host,
    region,
    credentials,
    domain_style: false,
  }
}

///|
/// 自定义域名（已绑定到某一个桶）那一档的构造器：**host 逐字就是那个域名**，
/// [Config::host_of] 不再拼桶名前缀（真桶实测：`<桶名>.<域名>` 连 DNS 都不解析，
/// 域名本身已经指向桶了）。解析纪律与 [Config::new] 同一份（见 [split_origin]）。
///
/// - `domain` 带不带 scheme 都收；前缀缺省时默认 `https`，也可用 `scheme~` 显式指定，
///   但**两种写法只能表达一个意思**（串与显式值不一致就 `BadParam`，见 [Config::new]）；
/// - `region` 照旧必填——它进的是签名 scope，跟寻址档位无关；
/// - 这一档的 http 是真桶量过的：80 端口由 `Server: OBS` 亲口应答，对象族与同桶复制全过；
///   443 因桶侧没绑证书停在 TLS（不是卡在签名），https 要先在桶侧把证书绑上。
pub fn Config::with_domain(
  domain : String,
  region : String,
  credentials : @auth.Credentials,
  scheme~ : String = "",
) -> Config raise @error.ObsError {
  if region.is_empty() {
    raise @error.BadParam("region is empty")
  }
  let (scheme, host) = split_origin(domain, "domain", scheme~)
  Config::{
    scheme,
    endpoint_host: host,
    region,
    credentials,
    domain_style: true,
  }
}

///|
/// 桶级主机名（vhost）。空桶名就是服务级主机（`GET /` 列桶那一条走它）。
/// 自定义域名档（[Config::with_domain]）走的是另一条：域名已经绑到桶，
/// 桶名不进 host，所以**任何**桶名（含空串）都返回同一个逐字域名。
pub fn Config::host_of(self : Config, bucket : String) -> String {
  if self.domain_style || bucket.is_empty() {
    self.endpoint_host
  } else {
    bucket + "." + self.endpoint_host
  }
}

///|
/// 请求 URL：`scheme://<vhost>/<编码后的键>`。键里的 `/` 保留（分段就是键的一部分）。
/// 空键就是桶根 `/`。
pub fn Config::url_of(
  self : Config,
  bucket : String,
  key~ : String = "",
) -> String {
  let base = self.scheme + "://" + self.host_of(bucket)
  if key.is_empty() {
    base + "/"
  } else {
    base + "/" + @auth.encode_object_key(key)
  }
}

///|
/// 签名用的规范化路径：**虚主机寻址下桶名不进路径**（官方 SDK 的
/// `getCanonicalURI(bucket, key)` 只在 path 风格时前置 `/<bucket>`，而 path 风格在本家
/// 收不到应答，见文件头）。于是三档就是：服务级 `/`、桶级 `/`、对象级 `/<编码键>`。
///
/// 这一条与隔壁 `moon-oss` 正相反——OSS 真桶实测要把桶名签进资源路径
/// （`/<bucket>/<key>`），照抄那边当场 `SignatureDoesNotMatch`。两家反着来，
/// 所以这里由测试单独钉住"不出现桶名段"。
pub fn Config::canonical_uri_of(
  _self : Config,
  bucket : String,
  key~ : String = "",
) -> String {
  // bucket 参数刻意不接进签名串：留它在签名面上只会被误用成 path 风格。
  // 想验这一点就看 `shape_test.mbt` 那条"桶名不出现在规范化路径里"。
  let _ = bucket
  if key.is_empty() {
    "/"
  } else {
    "/" + @auth.encode_object_key(key)
  }
}

///|
/// path 风格的 URL。**永远拒绝**，不是"返回一个也许能用的串"。
/// 实测读数：path 风格的对象请求一律 403 `VirtualHostDomainRequired`（832 字节正文），
/// 也就是说这一族地址在本家根本没有应答——把它做成功能会让人以为错在签名。
pub fn Config::path_style_url(
  _self : Config,
  bucket : String,
  key~ : String = "",
) -> String raise @error.ObsError {
  let target = if bucket.is_empty() {
    "the service root"
  } else {
    let path = if key.is_empty() { "" } else { "/" + key }
    "bucket " + bucket + path
  }
  raise @error.BadParam(
    "obs has no path-style addressing for " +
    target +
    ": a path-style request is answered 403 VirtualHostDomainRequired, use virtual-hosted style",
  )
}

///|
pub fn Config::region_of(self : Config) -> String {
  self.region
}

///|
pub fn Config::credentials(self : Config) -> @auth.Credentials {
  self.credentials
}

///|
/// 装配后的最终 scheme：前缀与显式 `scheme~` 对齐过的读数（见 [resolve_scheme]），
/// 不是"调用方给的那个串"。所以这一格永远只有 `http`／`https` 两个值。
pub fn Config::scheme_of(self : Config) -> String {
  self.scheme
}

///|
/// 是不是自定义域名那一档（[Config::with_domain] 造的才是）。
/// 给测试与下游适配层判档用：域名档里桶名不进 host，日志与文档拿这一格分辨。
pub fn Config::is_domain_style(self : Config) -> Bool {
  self.domain_style
}
