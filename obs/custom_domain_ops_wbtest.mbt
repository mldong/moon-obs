///|
test "custom domain document writes certificate fields" {
  let cert = CustomDomainCert::{
    name: "cert-1",
    certificate: "CERT",
    private_key: "KEY",
    certificate_id: "cid",
  }
  assert_eq(
    custom_domain_document(cert),
    "<CustomDomainConfiguration><Name>cert-1</Name><CertificateId>cid</CertificateId>" +
    "<Certificate>CERT</Certificate><PrivateKey>KEY</PrivateKey>" +
    "</CustomDomainConfiguration>",
  )
}

///|
test "custom domain list parse reads entries" {
  let body = "<ListBucketCustomDomainsResult><Domains>" +
    "<DomainName>cdn.example.com</DomainName><CertificateId>cid</CertificateId>" +
    "<Name>cert-1</Name><CertificateType>server</CertificateType>" +
    "<CreateTime>2026-10-22T00:00:00.000Z</CreateTime>" +
    "<ExpiredTime>2027-10-22T00:00:00.000Z</ExpiredTime></Domains>" +
    "</ListBucketCustomDomainsResult>"
  let items = parse_custom_domains(body)
  assert_eq(items.length(), 1)
  assert_eq(items[0].domain_name, "cdn.example.com")
  assert_eq(items[0].certificate_id, "cid")
  assert_eq(items[0].certificate_type, "server")
}
