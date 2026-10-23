///|
/// 一对 OBS 凭据。字段**不加** `pub(all)`，也**不派生** `Show`/`Debug`/`ToJson`：
/// `secret_key` 一旦能被外面读到，一条"打印出来看看"的调试语句或一次序列化就把它送进日志了。
/// 这条线两家先例（`moon-oss`/`moon-cos`）同口径，要读数走 `access_key()`。
pub struct Credentials {
  access_key : String
  secret_key : String
  security_token : String?
}

///|
/// 两把键任一为空就地拒——带着空键发出的请求只会在服务端变成一条看不出根因的 403。
pub fn Credentials::new(
  access_key : String,
  secret_key : String,
) -> Credentials raise @error.ObsError {
  if access_key.is_empty() {
    raise @error.BadParam("access key is empty")
  }
  if secret_key.is_empty() {
    raise @error.BadParam("secret key is empty")
  }
  Credentials::{ access_key, secret_key, security_token: None, }
}

///|
/// 公开的那半把键（错误文案与记账要带它，签名本身不外露密钥）。
pub fn Credentials::access_key(self : Credentials) -> String {
  self.access_key
}

///|
/// 挂一把 STS 临时令牌；空串视作"不挂"，返回自身。
pub fn Credentials::with_security_token(
  self : Credentials,
  token : String,
) -> Credentials {
  if token.is_empty() {
    self
  } else {
    Credentials::{
      access_key: self.access_key,
      secret_key: self.secret_key,
      security_token: Some(token),
    }
  }
}

///|
pub fn Credentials::security_token(self : Credentials) -> String? {
  self.security_token
}

///|
/// 用当前 UTC 时刻签一次请求（真请求走这条，longDate 由 SDK 内部取时钟）。
pub fn Credentials::sign(
  self : Credentials,
  region : String,
  request : RequestToSign,
  header_prefix~ : HeaderPrefix = default_header_prefix,
) -> Signature raise @error.ObsError {
  let timestamp = iso8601_basic(now_millis())
  sign_with_required_headers(
    self.access_key,
    self.secret_key,
    region,
    timestamp,
    request,
    header_prefix~,
  )
}

///|
/// 用**注入的时刻**签一次请求。测试与业务侧回放都靠它，`millis` 由调用方给，
/// 这样"注入时钟"这条路在 SDK 外面也是通的。
pub fn Credentials::sign_at(
  self : Credentials,
  region : String,
  millis : Int64,
  request : RequestToSign,
  header_prefix~ : HeaderPrefix = default_header_prefix,
) -> Signature raise @error.ObsError {
  let timestamp = iso8601_basic(millis)
  sign_with_required_headers(
    self.access_key,
    self.secret_key,
    region,
    timestamp,
    request,
    header_prefix~,
  )
}

///|
/// 两个必带头的固定件套：V4 必带的 `<prefix>date` 与 `<prefix>content-sha256`。
/// 值 `UNSIGNED-PAYLOAD` 是官方 SDK `CONTENT_SHA256` 的默认档——正文哈希不参与签名。
/// 前缀由 `HeaderPrefix` 给（原生 `x-obs-`／兼容 `x-amz-`），签名用的头名与发出去的头名
/// 必须逐字相同，所以这一处是唯一的出处。
pub fn required_headers(
  timestamp : String,
  prefix~ : HeaderPrefix = default_header_prefix,
) -> Array[(String, String)] {
  [
    (prefix.date_header(), timestamp),
    (prefix.content_sha256_header(), unsigned_payload),
  ]
}

///|
/// 把必带的两头并进调用方的头集合后签一次。`sign_v4` 签的是"传进来的每个头"，
/// 所以调用方给什么就签什么；这条门面只负责补上协议要求的两头与 host。
pub fn sign_with_required_headers(
  access_key : String,
  secret_key : String,
  region : String,
  timestamp : String,
  request : RequestToSign,
  header_prefix~ : HeaderPrefix = default_header_prefix,
) -> Signature raise @error.ObsError {
  let req = with_required_headers(request, timestamp, header_prefix~)
  sign_v4(access_key, secret_key, region, timestamp, req)
}

///|
/// 补头的那一步单独露出来：装配层要能拿同一份形状去核对"发出去的头"与"签进去的头"
/// 是不是同一批（差一个头就是一条 403）。
pub fn with_required_headers(
  request : RequestToSign,
  timestamp : String,
  header_prefix~ : HeaderPrefix = default_header_prefix,
) -> RequestToSign {
  RequestToSign::{
    verb: request.verb,
    canonical_uri: request.canonical_uri,
    query: request.query,
    headers: request.headers + required_headers(timestamp, prefix=header_prefix),
    payload_hash: request.payload_hash,
  }
}

///|
/// 本 SDK 读墙上时钟的**唯一一处**。要注入时钟（测试、回放）走 `Credentials::sign_at`，
/// 不要在这里改。
pub fn now_millis() -> Int64 {
  @date.now_millis()
}

///|
/// 用注入的时刻签一次**查询串**签名（预签名 URL 走这条）。密钥只在这一层被读到——
/// `Credentials` 的字段不公开，业务面拿不到 SK 也能出 URL。
///
/// 预签名**不补** `content-sha256` 那一头（那时正文未知），只补 `date` 之外由调用方
/// 自己给的 host——见 `presign_v4` 的注释。
pub fn Credentials::presign_at(
  self : Credentials,
  region : String,
  timestamp : String,
  expires : Int64,
  request : RequestToSign,
) -> PresignedUrl raise @error.ObsError {
  presign_v4(
    self.access_key,
    self.secret_key,
    region,
    timestamp,
    expires,
    request,
  )
}
