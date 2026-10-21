///|
/// OBS 的区域、凭据与端点派生。
///
/// 一条实测事实决定了这里的形状：**OBS 只有 virtual-hosted 寻址**。同一条对象请求走
/// path 风格（`https://obs.<region>.myhuaweicloud.com/<bucket>/<key>`）一律回
/// 403 `VirtualHostDomainRequired`（带正文，非空响应），本卡 §1 已实测。
/// 所以这里**不提供寻址风格开关**——没有可选项的东西做成配置，接入方会以为关掉它就能绕过；
/// 只留一条 [path_style_url]，谁调它就响亮拒绝。
///
/// 原生端点基址是 `obs.<region>.myhuaweicloud.com`，虚主机是 `<bucket>.<基址>`。
/// AWS 那套 `s3.<region>.…` 形态在本机连 DNS 都解析不到，别拿它当默认值。

///|
pub(all) struct Config {
  /// "https" 或 "http"（真端点只该用 https）
  scheme : String
  /// 形如 `obs.cn-south-1.myhuaweicloud.com`，不带 scheme、不带桶名前缀
  endpoint_host : String
  /// 签名 scope 用的区域 id，如 `cn-south-1`
  region : String
  credentials : @auth.Credentials
}

///|
/// OBS 服务端的基址（不含桶名）。纯函数，签名件与测试都要拿同一份派生规则。
pub fn native_endpoint_host(region : String) -> String {
  "obs." + region + ".myhuaweicloud.com"
}

///|
/// 只给区域就能装配：基址按 [native_endpoint_host] 派生。
pub fn Config::from_region(
  region : String,
  credentials : @auth.Credentials,
) -> Config raise @error.ObsError {
  if region.is_empty() {
    raise @error.BadParam("region is empty")
  }
  Config::new(native_endpoint_host(region), region, credentials)
}

///|
/// `endpoint` 接受带或不带 scheme 两种写法；带 `//` 之后authority 为空、或带路径尾巴的
/// 直接拒——那类输入十有八九是把控制台"访问域名"整串（含桶名或斜杠）粘了过来。
pub fn Config::new(
  endpoint : String,
  region : String,
  credentials : @auth.Credentials,
) -> Config raise @error.ObsError {
  if region.is_empty() {
    raise @error.BadParam("region is empty")
  }
  let trimmed = endpoint.trim().to_owned()
  if trimmed.is_empty() {
    raise @error.BadParam("endpoint is empty")
  }
  let scheme = if trimmed.has_prefix("https://") {
    "https"
  } else if trimmed.has_prefix("http://") {
    "http"
  } else {
    "https"
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
        raise @error.BadParam("endpoint carries a path after the host: " + rest)
      }
      rest[0:cut].to_owned()
    }
  }
  if host.is_empty() || host.contains(" ") {
    raise @error.BadParam("endpoint host is not usable: " + host)
  }
  Config::{ scheme, endpoint_host: host, region, credentials, }
}

///|
/// 桶级主机名（vhost）。空桶名就是服务级主机（`GET /` 列桶那一条走它）。
pub fn Config::host_of(self : Config, bucket : String) -> String {
  if bucket.is_empty() {
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
pub fn Config::scheme_of(self : Config) -> String {
  self.scheme
}
