///|
/// **V4 查询串签名**（预签名 URL）。与 Header 签名同一条规范化链，只差三处：
/// 凭据／时刻／有效期这三样从头部搬到查询参数里（参数名是 `X-Amz-*` 那一套，
/// 原生面也一样——官方 SDK 的 V4 预签名没有 `x-obs-` 版本的参数名），
/// `X-Amz-Signature` 最后才追加所以不入签，以及**不带上** `<prefix>content-sha256`
/// 那一头（生成 URL 时正文未知，负载声明走 `UNSIGNED-PAYLOAD`）。

///|
pub(all) struct PresignedUrl {
  /// 已排序、已编码的查询串（含 `X-Amz-Signature`），直接拼在 `scheme://host/path?` 之后
  query : String
  signature : String
  timestamp : String
  scope : String
  /// 参与签名的头名列表；预签名最常见的形状就是单独一个 `host`
  signed_headers : String
  canonical_request : String
  string_to_sign : String
}

///|
/// 有效期上限：永久密钥 7 天（604800 秒）。这里按这一档做界——超出一律 `BadParam`，
/// 而不是发出去等真端点回一条含糊的 403。**下限 1 秒同理**：0 或负数签得出串、
/// 但那份 URL 在服务端永远无效，属于"本地照签得出"的错。
let presign_max_seconds : Int64 = 604800L

///|
/// 预签名查询串里的五个参数名（AWS/OBS 同名，排序后进规范化查询串）。
let presign_algorithm_param : String = "X-Amz-Algorithm"

///|
let presign_credential_param : String = "X-Amz-Credential"

///|
let presign_date_param : String = "X-Amz-Date"

///|
let presign_expires_param : String = "X-Amz-Expires"

///|
let presign_signed_headers_param : String = "X-Amz-SignedHeaders"

///|
/// 临时凭据那一格（`X-Amz-Security-Token`）不在这里自动加：预签名用长期密钥时才免掉它，
/// 而"哪把密钥是临时的"由调用方知道。参数名同样是 `X-Amz-` 那一套（原生面也一样），
/// 需要时把它作为一条普通 query 传进来即可——它会自动排序进规范化查询串。
let presign_signature_param : String = "X-Amz-Signature"

///|
pub fn presign_v4(
  access_key : String,
  secret_key : String,
  region : String,
  timestamp : String,
  expires : Int64,
  req : RequestToSign,
) -> PresignedUrl raise @error.ObsError {
  if timestamp.length() < 15 {
    raise @error.BadParam(
      "timestamp must be YYYYMMDDTHHMMSSZ, got " + timestamp,
    )
  }
  if access_key.is_empty() || secret_key.is_empty() {
    raise @error.BadParam("both keys are required to presign")
  }
  if expires <= 0L || expires > presign_max_seconds {
    let limit = presign_max_seconds.to_string()
    raise @error.BadParam(
      "presign validity must be within 1.." +
      limit +
      " seconds, got " +
      expires.to_string(),
    )
  }
  let date = timestamp[0:8].to_owned()
  let scope = scope_of(date, region)
  // 负载这一格固定 UNSIGNED-PAYLOAD：URL 交给别人打开时正文根本还没定
  let unsigned = RequestToSign::{
    verb: req.verb,
    canonical_uri: req.canonical_uri,
    query: req.query,
    headers: req.headers,
    payload_hash: unsigned_payload,
  }
  let block = canonical_headers(unsigned.headers)
  let signed = signed_header_list(block.signed_names)
  let credential = access_key + "/" + scope
  let params : Array[(String, String)] = unsigned.query +
    [
      (presign_algorithm_param, algorithm),
      (presign_credential_param, credential),
      (presign_date_param, timestamp),
      (presign_expires_param, expires.to_string()),
      (presign_signed_headers_param, signed),
    ]
  let with_credentials = RequestToSign::{
    verb: unsigned.verb,
    canonical_uri: unsigned.canonical_uri,
    query: params,
    headers: unsigned.headers,
    payload_hash: unsigned.payload_hash,
  }
  let canonical = canonical_request(with_credentials)
  let string_to_sign = string_to_sign_of(timestamp, scope, canonical)
  let signature = signature_of(secret_key, date, region, string_to_sign)
  PresignedUrl::{
    query: canonical_query_string(params) +
    "&" +
    presign_signature_param +
    "=" +
    signature,
    signature,
    timestamp,
    scope,
    signed_headers: signed,
    canonical_request: canonical,
    string_to_sign,
  }
}
