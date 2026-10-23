///|
/// 自定义域：`GET/PUT/DELETE /?customdomain[=<domain>]`。华为 OBS 的
/// `setBucketCustomDomain` 可带证书材料，读口回 `Domains` 列表
/// （官方 Python `client.py:3111-3180` 与 `convertor.py:714-741/1442-1461`，
/// 2026-10-22 现读）。本版覆盖域名 + 可选证书（名称/证书/私钥/证书 ID）。
pub(all) struct CustomDomainCert {
  name : String
  certificate : String
  private_key : String
  certificate_id : String
}

///|
pub(all) struct CustomDomainInfo {
  domain_name : String
  certificate_id : String
  name : String
  certificate_type : String
  create_time : String
  expired_time : String
}

///|
pub async fn Client::set_bucket_custom_domain(
  self : Client,
  bucket : String,
  domain : String,
  cert~ : CustomDomainCert? = None,
) -> Unit raise @error.ObsError {
  if domain.is_empty() {
    raise @error.BadParam("set_bucket_custom_domain needs a domain")
  }
  let body = match cert {
    None => None
    Some(info) => {
      if info.name.is_empty() ||
        info.certificate.is_empty() ||
        info.private_key.is_empty() {
        raise @error.BadParam(
          "certificate needs name, certificate and private_key",
        )
      }
      Some(custom_domain_document(info))
    }
  }
  let headers = match body {
    Some(_) => [("content-type", "application/xml")]
    None => []
  }
  let payload = match body {
    Some(text) => @transport.RequestBody::Bytes(@utf8.encode(text.view()))
    None => @transport.RequestBody::Empty
  }
  let response = request(
    self,
    "PUT",
    bucket,
    query=[("customdomain", domain)],
    extra_headers=headers,
    body=payload,
  )
  discard_body(response)
}

///|
pub async fn Client::get_bucket_custom_domains(
  self : Client,
  bucket : String,
) -> Array[CustomDomainInfo] raise @error.ObsError {
  let response = request(self, "GET", bucket, query=[("customdomain", "")])
  let body = response_body_text(response.body, response.status)
  parse_custom_domains(body)
}

///|
pub async fn Client::delete_bucket_custom_domain(
  self : Client,
  bucket : String,
  domain : String,
) -> Unit raise @error.ObsError {
  if domain.is_empty() {
    raise @error.BadParam("delete_bucket_custom_domain needs a domain")
  }
  let response = request(self, "DELETE", bucket, query=[
    ("customdomain", domain),
  ])
  discard_body(response)
}

///|
fn custom_domain_document(cert : CustomDomainCert) -> String {
  let mut out = "<CustomDomainConfiguration><Name>" +
    xml_escape(cert.name) +
    "</Name>"
  if !cert.certificate_id.is_empty() {
    out = out +
      "<CertificateId>" +
      xml_escape(cert.certificate_id) +
      "</CertificateId>"
  }
  out = out + "<Certificate>" + xml_escape(cert.certificate) + "</Certificate>"
  out = out + "<PrivateKey>" + xml_escape(cert.private_key) + "</PrivateKey>"
  out + "</CustomDomainConfiguration>"
}

///|
fn parse_custom_domains(body : String) -> Array[CustomDomainInfo] {
  let out : Array[CustomDomainInfo] = []
  for section in xml_sections(body, "Domains") {
    out.push(CustomDomainInfo::{
      domain_name: xml_first(section, "DomainName").unwrap_or(""),
      certificate_id: xml_first(section, "CertificateId").unwrap_or(""),
      name: xml_first(section, "Name").unwrap_or(""),
      certificate_type: xml_first(section, "CertificateType").unwrap_or(""),
      create_time: xml_first(section, "CreateTime").unwrap_or(""),
      expired_time: xml_first(section, "ExpiredTime").unwrap_or(""),
    })
  }
  out
}
