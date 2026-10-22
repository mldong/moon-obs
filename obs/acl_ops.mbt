///|
/// 对象级 ACL 两条（canned ACL 那一族）。
///
/// 写侧是 `PUT /<key>?acl=` + 头 `<prefix>acl: <取值>`（真桶口径见 [signed_prefix]），
/// 读侧是 `GET /<key>?acl=` 回
/// `AccessControlPolicy`。这一族的价值有一半在**签名**上：`acl` 是无值参数，
/// OBS 的规范化查询串写 `acl=`（带等号），OSS 那边写光键名——两处不对照就会一边绿一边红。
///
/// **取值面不在这里写死**：`private`／`public-read` 等各家都有，但 OBS 原生面还认
/// `log-delivery-read`／`encrypt-decrypt-read` 这类本家特有的档，哪些真收由
/// `live_test.mbt` 逐档实测并打印（含回体里 grant 的拼法），不在代码里"应该"。

///|
pub async fn Client::put_object_acl(
  self : Client,
  bucket : String,
  key : String,
  acl : String,
) -> Unit raise @error.ObsError {
  if acl.is_empty() {
    raise @error.BadParam("acl value is required")
  }
  let response = request(self, "PUT", bucket, key~, query=[("acl", "")], extra_headers=[
    (acl_header_name(), acl),
  ])
  discard_body(response)
}

///|
/// 读回一个对象的授权列表。
/// 元素名一律**按局部名取**（回体带 `xmlns="http://obs.myhwclouds.com/doc/2015-06-30/"`，
/// 按整串匹配会把"有命名空间"读成"字段不存在"）；命名空间本身作为一个读数留在
/// [ObjectAcl.default_ns] 里，供打印与对账。
pub async fn Client::get_object_acl(
  self : Client,
  bucket : String,
  key : String,
) -> ObjectAcl raise @error.ObsError {
  let response = request(self, "GET", bucket, key~, query=[("acl", "")])
  let body = response_body_text(response.body, response.status)
  parse_acl(body)
}

///|
pub async fn Client::put_bucket_acl(
  self : Client,
  bucket : String,
  acl : String,
) -> Unit raise @error.ObsError {
  if acl.is_empty() {
    raise @error.BadParam("acl value is required")
  }
  let response = request(self, "PUT", bucket, query=[("acl", "")], extra_headers=[
    (acl_header_name(), acl),
  ])
  discard_body(response)
}

///|
pub async fn Client::get_bucket_acl(
  self : Client,
  bucket : String,
) -> ObjectAcl raise @error.ObsError {
  let response = request(self, "GET", bucket, query=[("acl", "")])
  let body = response_body_text(response.body, response.status)
  parse_acl(body)
}

///|
fn parse_acl(body : String) -> ObjectAcl {
  let policy = xml_element(body, "AccessControlPolicy")
  let default_ns = match policy {
    None => None
    Some(elem) => elem.ns_decl("xmlns")
  }
  let owner = match xml_element(body, "Owner") {
    None => None
    Some(elem) => xml_first(elem.content, "ID")
  }
  let grants : Array[Grant] = []
  for elem in xml_elements(body, "Grant") {
    let grantee = xml_element(elem.content, "Grantee")
    let (gtype, gid, guri, gemail) = match grantee {
      None => ("", None, None, None)
      Some(one) =>
        (
          or_empty(one.attr("type")),
          xml_first(one.content, "ID"),
          xml_first(one.content, "URI"),
          xml_first(one.content, "EmailAddress"),
        )
    }
    grants.push(Grant::{
      grantee_type: gtype,
      grantee_id: gid,
      grantee_uri: guri,
      grantee_email: gemail,
      permission: or_empty(xml_first(elem.content, "Permission")),
    })
  }
  ObjectAcl::{ grants, owner_id: owner, default_ns, body, }
}

///|
/// 授权条数（打印用，不代替 `grants.length()`）。
pub fn ObjectAcl::grant_count(self : ObjectAcl) -> Int32 {
  self.grants.length()
}
