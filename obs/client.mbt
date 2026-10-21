///|
/// OBS 原生协议客户端。一处形状先说清：**寻址只有虚主机一档**（`<bucket>.obs.<region>.…`），
/// path 风格在真端点收不到应答（403 `VirtualHostDomainRequired`，本卡 §1 实测），
/// 所以这里没有 `addressing_style` 这类开关。
pub struct Client {
  config : @config.Config
  transport : &@transport.Transport
}

///|
/// 传输层是注入的（与 `moon-oss`／`moon-cos`／`moon-s3` 同一套端口）：业务侧可以换成带
/// 连接池、带自定义超时的实现，测试侧可以塞假端点。
pub fn Client::new(
  config : @config.Config,
  transport : &@transport.Transport,
) -> Client {
  Client::{ config, transport, }
}

///|
/// 本客户端签名与线格式用的头名前缀。
///
/// **实测读数（2026-10-19 真桶，原生端点 `obs.<region>.myhuaweicloud.com`）**：
/// V4 这一族只认 `x-amz-*`——把 `x-obs-date`／`x-obs-content-sha256` 换上去，GET 与 PUT
/// 都回 `400 InvalidArgument`，正文文案逐字是
/// `Missing required header for this request: x-amz-content-sha256`；
/// 只带 `x-obs-acl`（不带 `x-amz-acl`）的 `PUT /key?acl=` 回 `400 MissingSecurityHeader`。
/// 参照实现同一处对得上：官方 Python SDK 的 `V4Authentication` 只在 `signature == 'v4'`
/// 时装配，而那一档拿的适配器是 `Adapter('v4')`，`is_obs` 为假 ⇒ 前缀恒为 `x-amz-`；
/// `x-obs-*` 那一族属于 `signature == 'obs'` 的 **V2** 线（`OBS ak:signature`，HMAC-SHA1），
/// 本包按 owner 的口径只做 V4，所以这里不披 `x-obs-*` 的头。
///
/// 前缀仍是**一处开关**（不是散落各处的字面量）：签名串里的头名与发到线上的头名必须逐字相同，
/// 两处各写一遍就会各错一半。
pub let signed_prefix : @auth.HeaderPrefix = @auth.HeaderPrefix::Amz

///|
/// 元数据头前缀（`<prefix>meta-`）。写侧与读侧共用这一处派生。
fn meta_header_prefix() -> String {
  signed_prefix.text() + "meta-"
}

///|
fn acl_header_name() -> String {
  signed_prefix.acl_header()
}

///|
fn copy_source_header_name() -> String {
  signed_prefix.text() + "copy-source"
}

///|
pub fn Client::config_of(self : Client) -> @config.Config {
  self.config
}
