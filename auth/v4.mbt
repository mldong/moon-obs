///|
/// 华为云 OBS 的 **V4 签名**（原生面）。字面量与逐条规则取自官方 Python SDK
/// `huaweicloud-sdk-python-obs` 的 `src/obs/auth.py`（`V4Authentication`）、`const.py`、
/// `convertor.py`（头名适配器）、`util.py`（`encode_item`／`encode_object_key`），
/// 对应关系写在下面每个函数上。
///
/// 一句话形状的总纲：**OBS V4 就是 AWS SigV4 的构造**——算法串就叫 `AWS4-HMAC-SHA256`、
/// scope 的服务名就叫 `s3`、密钥链就是 `'AWS4'+SK` 起头的四条——差别全在装配层：
/// `Authorization` 逗号后**没有空格**、负载声明默认 `UNSIGNED-PAYLOAD`、头名前缀
/// `x-obs-`／`x-amz-` 二选一、以及"**传进来的每个头都签**"（AWS SDK 会挑子集，OBS 官方 SDK 不挑）。
/// 照隔壁 `moon-s3` 的 AWS 直觉改这几处一定红，所以每一处都单独钉了用例。
///
/// 为什么时间戳是入参而不是内部取时钟：签名向量测试必须能钉死一整个"请求→签名"样本，
/// 挂在 `now()` 上的测试既不可复现，也分不清"签名算错"与"时钟漂移"。

///|
/// 算法串。**不是** `OBS4-HMAC-SHA256`——这一点最容易想当然，官方 SDK 的三处字面量
/// （`outPut`、`auth` 前缀、`X-Amz-Algorithm` 取值）写的都是 `AWS4-HMAC-SHA256`。
pub let algorithm : String = "AWS4-HMAC-SHA256"

///|
/// 负载声明的默认值：官方 SDK 的 `V4Authentication.CONTENT_SHA256`。
/// 与 AWS SDK 的"默认发真实 sha256"反着来——这里签名不读正文。
pub let unsigned_payload : String = "UNSIGNED-PAYLOAD"

///|
/// scope 里写死的服务名（官方 SDK `getCredential`／`getScope` 的 `%s/s3/aws4_request`）。
let v4_service : String = "s3"

///|
/// 密钥链最后一段（官方 SDK `getSigningKey_python3` 的 `'aws4_request'`）。
let v4_request_marker : String = "aws4_request"

///|
/// 密钥链的第一段前缀（官方 SDK 的 `key = 'AWS4' + self.sk`）。
let v4_key_seed : String = "AWS4"

///|
/// 头名前缀：原生面 `x-obs-`、兼容面 `x-amz-`（官方 SDK `convertor.py` 的
/// `_get_header_prefix`，由 `signature == 'obs'` 二选一）。`date`／`content-sha256`／
/// `security-token`／`acl` 全跟着这一个开关换前缀，所以做成参数而不是写死——
/// 签名串里的头名与实际发出的头名必须逐字相同，两处各写一遍就会各错一半。
pub(all) enum HeaderPrefix {
  Obs
  Amz
}

///|
/// 默认走原生前缀（这条线接的是 OBS 原生协议面，不是 S3 兼容面）。
pub let default_header_prefix : HeaderPrefix = Obs

///|
pub fn HeaderPrefix::text(self : HeaderPrefix) -> String {
  match self {
    Obs => "x-obs-"
    Amz => "x-amz-"
  }
}

///|
pub fn HeaderPrefix::date_header(self : HeaderPrefix) -> String {
  self.text() + "date"
}

///|
pub fn HeaderPrefix::content_sha256_header(self : HeaderPrefix) -> String {
  self.text() + "content-sha256"
}

///|
pub fn HeaderPrefix::security_token_header(self : HeaderPrefix) -> String {
  self.text() + "security-token"
}

///|
pub fn HeaderPrefix::acl_header(self : HeaderPrefix) -> String {
  self.text() + "acl"
}

///|
/// 一次签名所需的全部输入。字段是"调用方已经决定好的形状"：
/// 寻址风格（path／vhost）与区域由上层决定并拼进 `canonical_uri`，签名器不看配置。
/// `payload_hash` 留成入参而不是写死 `UNSIGNED-PAYLOAD`：官方 SDK 的
/// `getSignature(..., payload=None)` 就是这个形状（None 时落 `CONTENT_SHA256`），
/// 而且签名向量测试必须能喂真实 sha256 才能与外部权威对上。
pub(all) struct RequestToSign {
  /// 大写的 HTTP 动词，如 "GET"／"PUT"
  verb : String
  /// 规范化后的资源路径（已编码），见 `canonical_uri`
  canonical_uri : String
  /// 查询参数（未编码的原值）
  query : Array[(String, String)]
  /// 参与签名的头。**全部入签**（OBS 无 allowlist），大小写随意、内部统一转小写并排序；
  /// `authorization` 不许出现在这里，见 `canonical_headers`
  headers : Array[(String, String)]
  /// 规范化请求的最后一行；默认 `UNSIGNED-PAYLOAD`
  payload_hash : String
}

///|
/// 常用的那个形状：负载不参签（官方默认档）。
pub fn RequestToSign::new(
  verb : String,
  canonical_uri : String,
  query~ : Array[(String, String)] = [],
  headers~ : Array[(String, String)] = [],
  payload_hash~ : String = unsigned_payload,
) -> RequestToSign {
  { verb, canonical_uri, query, headers, payload_hash, }
}

///|
/// 一次签名的全部读数。`canonical_request` 与 `string_to_sign` 都留着：
/// 排障时这两串就是证据，而它们**不含任何密钥**。
pub(all) struct Signature {
  authorization : String
  /// 参与签名的头名（小写、字典序、分号分隔）；OBS 总是发出这一字段，空集合时是空串
  signed_headers : String
  scope : String
  timestamp : String
  canonical_request : String
  string_to_sign : String
  signature : String
}

///|
/// 头块 + 参与签名的头名（字典序、已去重）。返回类型必须是命名结构：
/// 匿名结构体不能出现在顶层签名的返回位置。
pub(all) struct HeaderBlock {
  block : String
  signed_names : Array[String]
}

///|
/// 百分号编码：未保留字符 = 字母数字 + `-._~`，其余按 UTF-8 逐字节写成 `%XX`（大写），
/// 空格是 `%20` 而不是 `+`。`keep_slash` 为真时 `/` 原样保留。
///
/// 对应官方 SDK 的 `encode_item(item, safe)`：键用 `safe='/'`、值用 `safe=''`，
/// 而 `encode_object_key` 用 `safe='/~'`。`~` 本来就在未保留集里，
/// 所以"逐段编码 + 保留 `/`"与 `safe='/~'` 等价。
pub fn encode_item(text : String, keep_slash~ : Bool = false) -> String {
  if !keep_slash {
    return @percent.encode(text.view())
  }
  let mut out = ""
  let mut first = true
  for segment in text.split("/") {
    if !first {
      out = out + "/"
    }
    first = false
    out = out + @percent.encode(segment)
  }
  out
}

///|
/// 旧名保留给读惯 AWS 文档的人：与 `encode_item(keep_slash=true)` 同一条。
pub fn uri_encode(text : String, keep_slash~ : Bool = false) -> String {
  encode_item(text, keep_slash~)
}

///|
/// 对象键／路径的编码（官方 SDK `encode_object_key`：整串 `quote(key, safe='/~')`）。
pub fn encode_object_key(key : String) -> String {
  encode_item(key, keep_slash=true)
}

///|
/// 规范化资源路径（官方 SDK `getCanonicalURI`，逐字对应）：
/// path 风格且有桶名时前置 `/<bucket>`，有键时再拼 `/<key>`，两样都空时是 `/`，
/// 最后整串走 `encode_object_key`。
///
/// 这是 OBS 与 OSS 的一处**反向**差别：OSS 只收 vhost 且签的是"编码后的键"，
/// OBS 原生面两种寻址都支持、path 风格要把桶名一起签进去（官方 SDK 现读）。
pub fn canonical_uri(
  bucket~ : String = "",
  key~ : String = "",
  path_style~ : Bool = true,
) -> String {
  let mut uri = ""
  if path_style && !bucket.is_empty() {
    uri = uri + "/" + bucket
  }
  if !key.is_empty() {
    uri = uri + "/" + key
  }
  if uri.is_empty() {
    uri = "/"
  }
  encode_object_key(uri)
}

///|
/// ASCII 码位比较折成 -1/0/1。不能直接用 core 的 `String.compare`：它先比长度再比内容，
/// 拿来排序会把 `b` 排到 `aa` 后面，签名当场对不上。
fn compare_string(a : String, b : String) -> Int32 {
  let ac = a.to_array()
  let bc = b.to_array()
  let n = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  let mut i = 0
  while i < n {
    let x = ac[i].to_int()
    let y = bc[i].to_int()
    if x < y {
      return -1
    }
    if x > y {
      return 1
    }
    i = i + 1
  }
  ac.length() - bc.length()
}

///|
/// 插入排序：这里的数组都是个位数长度，用库排序还要引入 `Ordering` 类型名，
/// 反而多一处会错的地方。
fn[T] insertion_sort(items : Array[T], less : (T, T) -> Bool) -> Array[T] {
  let sorted : Array[T] = []
  for item in items {
    let mut placed = false
    let mut index = 0
    while index < sorted.length() && !placed {
      if less(item, sorted[index]) {
        placed = true
      } else {
        index = index + 1
      }
    }
    sorted.insert(index, item)
  }
  sorted
}

///|
fn is_space(c : Char) -> Bool {
  let x = c.to_int()
  x == 32 || x == 9 || x == 10 || x == 13
}

///|
/// 头值归一：去首尾空白、内部连续空白折成一个空格。签名算的是这一串，
/// 发出去的是另一串，两边规则不同就会各对一半。
pub fn normalize_header_value(value : String) -> String {
  let chars = value.to_array()
  let mut start = 0
  while start < chars.length() && is_space(chars[start]) {
    start = start + 1
  }
  let mut end = chars.length()
  while end > start && is_space(chars[end - 1]) {
    end = end - 1
  }
  let out : Array[Char] = []
  let mut pending_space = false
  for i in start..<end {
    let c = chars[i]
    if is_space(c) {
      pending_space = true
    } else {
      if pending_space && !out.is_empty() {
        out.push(' ')
      }
      pending_space = false
      out.push(c)
    }
  }
  String::from_array(out)
}

///|
/// 头名/头值两侧的首尾空白。`String.trim` 给的是 `StringView`，
/// 这里要的是能继续拼装的 `String`。
fn trim_ascii(text : String) -> String {
  text.trim().to_owned()
}

///|
/// 规范化查询串（官方 SDK `getCanonicalQueryString` 逐字对应）：
///
/// - **同名键折叠**：SDK 把 `args_path` 灌进 dict（`canonMap[key] = value`），后进的赢；
///   这与 AWS SigV4"同名两值都写"的形状不同（`moon-s3` 那条 `x=1&x=2` 向量在 OBS 形状下
///   对不上，原因就在这格）。
/// - 按**原始键**排序（`sorted(..., key=lambda d: d[0])` 排的是编码前的形状）。
/// - 键用 `encode_item(k, '/')`（`/` 保留）、值用 `encode_item(v, '')`（`/` 编成 `%2F`）。
/// - 每对都写成 `k=v`——**空值也带 `=`**（`'%s=%s'`）。这一条与 OSS V4 反着来：
///   OSS 的子资源参数是光一个键名不带 `=`。
pub fn canonical_query_string(query : Array[(String, String)]) -> String {
  if query.is_empty() {
    return ""
  }
  let merged : Array[(String, String)] = []
  for pair in query {
    let key = trim_ascii(pair.0)
    let value = trim_ascii(pair.1)
    let mut hit = false
    for i in 0..<merged.length() {
      if merged[i].0 == key {
        let last = (key, value)
        merged[i] = last
        hit = true
      }
    }
    if !hit {
      merged.push((key, value))
    }
  }
  let ordered = insertion_sort(merged, (a, b) => {
    let by_key = compare_string(a.0, b.0)
    if by_key == 0 {
      compare_string(a.1, b.1) < 0
    } else {
      by_key < 0
    }
  })
  let mut out = ""
  for i in 0..<ordered.length() {
    if i > 0 {
      out = out + "&"
    }
    let key = encode_item(ordered[i].0, keep_slash=true)
    let value = encode_item(ordered[i].1)
    out = out + key + "=" + value
  }
  out
}

///|
/// 规范化头块：**传进来的头全部入签**（OBS 官方 SDK 不做 allowlist 挑选：
/// `headMap = setMapKeyLower(headers)` 之后逐条落地）。名字统一小写、值归一，
/// 按名字字典序，**每行自带换行**；同名多值按值排序后各占一行
/// （官方 SDK `getCanonicalHeaders` 对 list 值先 `sorted` 再逐条写）。
///
/// 唯一的例外是 `authorization`：它是签名结果的载体，签它自己就成了循环，
/// 所以那种输入直接拒掉而不是悄悄丢掉一格。
pub fn canonical_headers(
  headers : Array[(String, String)],
) -> HeaderBlock raise @error.ObsError {
  let rows : Array[(String, String)] = []
  for pair in headers {
    let name = trim_ascii(pair.0).to_lower()
    if name == "authorization" {
      raise @error.BadParam(
        "the authorization header is the carrier of the signature and must not be signed",
      )
    }
    if !name.is_empty() {
      rows.push((name, trim_ascii(pair.1)))
    }
  }
  let ordered = insertion_sort(rows, (a, b) => {
    let by_key = compare_string(a.0, b.0)
    if by_key == 0 {
      compare_string(a.1, b.1) < 0
    } else {
      by_key < 0
    }
  })
  let mut block = ""
  let names : Array[String] = []
  let mut last = ""
  for pair in ordered {
    block = block + pair.0 + ":" + normalize_header_value(pair.1) + "\n"
    // SignedHeaders 里头名只出现一次（SDK 那边头名是 dict 键）
    if pair.0 != last {
      names.push(pair.0)
      last = pair.0
    }
  }
  HeaderBlock::{ block, signed_names: names, }
}

///|
/// 参与签名的头名列表：字典序、分号分隔（官方 SDK `getSignedHeaders`）。
pub fn signed_header_list(names : Array[String]) -> String {
  let ordered = insertion_sort(names, (a, b) => compare_string(a, b) < 0)
  let mut out = ""
  for i in 0..<ordered.length() {
    if i > 0 {
      out = out + ";"
    }
    out = out + ordered[i]
  }
  out
}

///|
/// 完整六行：`METHOD \n URI \n QUERY \n HEADERS \n SIGNEDHEADERS \n PAYLOADHASH`。
/// 头块自身已以换行结尾，所以行与行之间各一个换行、头块后多出一个空行——
/// 少一个或多一个都是签名不符，这里逐行绑定，不在拼装表达式里随手加分隔。
pub fn canonical_request(req : RequestToSign) -> String raise @error.ObsError {
  let headers = canonical_headers(req.headers)
  let line1 = req.verb + "\n"
  let line2 = req.canonical_uri + "\n"
  let line3 = canonical_query_string(req.query) + "\n"
  let line4 = headers.block + "\n"
  let line5 = signed_header_list(headers.signed_names) + "\n"
  let line6 = req.payload_hash
  line1 + line2 + line3 + line4 + line5 + line6
}

///|
/// scope：`<shortDate>/<region>/s3/aws4_request`（官方 SDK `getScope`，服务名写死 `s3`）。
pub fn scope_of(date : String, region : String) -> String {
  date + "/" + region + "/" + v4_service + "/" + v4_request_marker
}

///|
/// 派生密钥链（官方 SDK `getSigningKey_python3` 原样四条）：
/// `HMAC(HMAC(HMAC(HMAC("AWS4"+SK, Date), Region), "s3"), "aws4_request")`。
/// 与 AWS SigV4 逐字相同，与 OSS V4（`"aliyun_v4"` 起头、尾段 `aliyun_v4_request`）不同名。
pub fn signing_key(
  secret_key : String,
  date : String,
  region : String,
) -> Bytes {
  let key0 = @digest.hmac_sha256_of_bytes(
    @utf8.encode((v4_key_seed + secret_key).view()),
    @utf8.encode(date.view()),
  )
  let key1 = @digest.hmac_sha256_of_bytes(key0, @utf8.encode(region.view()))
  let key2 = @digest.hmac_sha256_of_bytes(key1, @utf8.encode(v4_service.view()))
  @digest.hmac_sha256_of_bytes(key2, @utf8.encode(v4_request_marker.view()))
}

///|
/// 派生密钥的一行十六进制读数。向量测试要钉它（密钥链任何一条边写错，签名都会变成
/// 另一串却仍然"形状合法"）；它**不是** SK，但同样不许进日志。
pub fn signing_key_hex(
  secret_key : String,
  date : String,
  region : String,
) -> String {
  @hex.encode(signing_key(secret_key, date, region))
}

///|
/// StringToSign 四行。Header 签名与查询串签名共用同一条：两代只差"结果写进哪个位置"，
/// 规范化算法差一个字都要全线 403，所以不许两处各写一遍。
pub fn string_to_sign_of(
  timestamp : String,
  scope : String,
  canonical : String,
) -> String {
  algorithm +
  "\n" +
  timestamp +
  "\n" +
  scope +
  "\n" +
  @digest.sha256_hex(canonical)
}

///|
/// 签名值 = HMAC-SHA256(signingKey, stringToSign) 的**小写 hex**（官方 SDK `hmacSha256`）。
/// 与 V2 的分界就在这一格：V2 是 HMAC-SHA1 + base64，混了不会报错、只会一直 403。
pub fn signature_of(
  secret_key : String,
  date : String,
  region : String,
  string_to_sign : String,
) -> String {
  @digest.hmac_sha256_hex_of_bytes(
    signing_key(secret_key, date, region),
    @utf8.encode(string_to_sign.view()),
  )
}

///|
/// `Authorization` 的拼装（官方 SDK `doAuth` 的格式串逐字对应）：
/// `AWS4-HMAC-SHA256 Credential=<ak>/<scope>,SignedHeaders=<list>,Signature=<hex>`。
///
/// **逗号后没有空格**——AWS SDK 发的是带空格那一形，两家服务端都收，但我们钉的是 OBS
/// 那一串：形状写歪时向量测试照样绿（签名值本身没错），线上却与"逐字对齐官方 SDK"这条
/// 验收线不符，所以单独钉一条用例。
pub fn authorization_of(
  access_key : String,
  scope : String,
  signed_headers : String,
  signature : String,
) -> String {
  let credential = access_key + "/" + scope
  algorithm +
  " Credential=" +
  credential +
  ",SignedHeaders=" +
  signed_headers +
  ",Signature=" +
  signature
}

///|
/// `timestamp` 必须是 longDate 基本格式（`YYYYMMDDTHHMMSSZ`，UTC），短日期直接前缀取。
pub fn sign_v4(
  access_key : String,
  secret_key : String,
  region : String,
  timestamp : String,
  req : RequestToSign,
) -> Signature raise @error.ObsError {
  if timestamp.length() < 15 {
    raise @error.BadParam(
      "timestamp must be YYYYMMDDTHHMMSSZ, got " + timestamp,
    )
  }
  if access_key.is_empty() || secret_key.is_empty() {
    raise @error.BadParam("both keys are required to sign")
  }
  let date = timestamp[0:8].to_owned()
  let scope = scope_of(date, region)
  let canonical = canonical_request(req)
  let headers = canonical_headers(req.headers)
  let signed = signed_header_list(headers.signed_names)
  let string_to_sign = string_to_sign_of(timestamp, scope, canonical)
  let signature = signature_of(secret_key, date, region, string_to_sign)
  let authorization = authorization_of(access_key, scope, signed, signature)
  Signature::{
    authorization,
    signed_headers: signed,
    scope,
    timestamp,
    canonical_request: canonical,
    string_to_sign,
    signature,
  }
}

///|
/// longDate（`20261016T010203Z`）：`x-obs-date` 的头值与 StringToSign 第二行都用它。
/// 时钟是入参：向量测试要能钉住一个时刻，不能挂在 `now()` 上。
/// 区名写死 "UTC"——签名协议要的是 UTC 读数，读本机时区会签出一个"看着对"的错串。
pub fn iso8601_basic(millis : Int64) -> String raise @error.ObsError {
  match @date.now_at("UTC", @date.clock_fixed(millis)) {
    None =>
      raise @error.BadParam(
        "epoch millis outside the zone table: " + millis.to_string(),
      )
    Some(dt) => {
      let day = dt.date
      let year = pad(day.year, 4)
      let month = pad(day.month, 2)
      let date_of_day = pad(day.day, 2)
      let hour = pad(dt.hour, 2)
      let minute = pad(dt.minute, 2)
      let second = pad(dt.second, 2)
      year + month + date_of_day + "T" + hour + minute + second + "Z"
    }
  }
}

///|
/// shortDate（`20261016`）：scope 的第一段，也是密钥链的第二段。
pub fn date_stamp(millis : Int64) -> String raise @error.ObsError {
  let long = iso8601_basic(millis)
  long[0:8].to_owned()
}

///|
fn pad(value : Int32, width : Int32) -> String {
  let text = value.to_string()
  let mut missing = width - text.length()
  if missing <= 0 {
    return text
  }
  let mut zeros = ""
  while missing > 0 {
    zeros = zeros + "0"
    missing = missing - 1
  }
  zeros + text
}
