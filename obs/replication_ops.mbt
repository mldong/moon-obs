///|
/// 桶复制：`GET/PUT/DELETE /?replication`。华为 OBS 的 XML 是
/// `<ReplicationConfiguration><Agency/><Rule>...`（官方 Python `convertor.py:1226-1258`,
/// 2026-10-22 现读）：规则里的目标桶与存储类在 `<Destination>` 下，
/// `DeleteData` 与 `HistoricalObjectReplication` 是 OBS 的扩展档。
pub(all) struct ReplicationRule {
  id : String
  prefix : String
  status : String
  destination_bucket : String
  storage_class : String
  delete_data : String
  historical_object_replication : String
}

///|
pub(all) struct ReplicationConfig {
  agency : String
  rules : Array[ReplicationRule]
}

///|
pub fn ReplicationRule::new(
  id : String,
  destination_bucket : String,
  status~ : String = "Enabled",
  prefix~ : String = "",
) -> ReplicationRule {
  ReplicationRule::{
    id,
    prefix,
    status,
    destination_bucket,
    storage_class: "",
    delete_data: "",
    historical_object_replication: "Disabled",
  }
}

///|
pub async fn Client::put_bucket_replication(
  self : Client,
  bucket : String,
  config : ReplicationConfig,
) -> Unit raise @error.ObsError {
  if config.rules.is_empty() {
    raise @error.BadParam("put_bucket_replication needs at least one rule")
  }
  for rule in config.rules {
    if rule.destination_bucket.is_empty() {
      raise @error.BadParam(
        "replication rule without a destination bucket: " + rule.id,
      )
    }
    if rule.status != "Enabled" && rule.status != "Disabled" {
      raise @error.BadParam(
        "replication rule status must be Enabled or Disabled, got " +
        rule.status,
      )
    }
  }
  let document = replication_document(config)
  let response = request(
    self,
    "PUT",
    bucket,
    query=[("replication", "")],
    extra_headers=[("content-type", "application/xml")],
    body=@transport.RequestBody::Bytes(@utf8.encode(document.view())),
  )
  discard_body(response)
}

///|
pub async fn Client::get_bucket_replication(
  self : Client,
  bucket : String,
) -> ReplicationConfig? raise @error.ObsError {
  let response = request(self, "GET", bucket, query=[("replication", "")]) catch {
    err =>
      match err {
        @error.ObsError::Service(details) =>
          if details.status == 404 {
            return None
          } else {
            raise err
          }
        _ => raise err
      }
  }
  let body = response_body_text(response.body, response.status)
  Some(parse_replication(body))
}

///|
pub async fn Client::delete_bucket_replication(
  self : Client,
  bucket : String,
) -> Unit raise @error.ObsError {
  let response = request(self, "DELETE", bucket, query=[("replication", "")])
  discard_body(response)
}

///|
fn replication_document(config : ReplicationConfig) -> String {
  let mut out = "<ReplicationConfiguration>"
  if !config.agency.is_empty() {
    out = out + "<Agency>" + xml_escape(config.agency) + "</Agency>"
  }
  for rule in config.rules {
    out = out + "<Rule><ID>" + xml_escape(rule.id) + "</ID>"
    out = out + "<Prefix>" + xml_escape(rule.prefix) + "</Prefix>"
    out = out + "<Status>" + xml_escape(rule.status) + "</Status>"
    if !rule.historical_object_replication.is_empty() {
      out = out +
        "<HistoricalObjectReplication>" +
        xml_escape(rule.historical_object_replication) +
        "</HistoricalObjectReplication>"
    }
    out = out +
      "<Destination><Bucket>" +
      xml_escape(rule.destination_bucket) +
      "</Bucket>"
    if !rule.storage_class.is_empty() {
      out = out +
        "<StorageClass>" +
        xml_escape(rule.storage_class) +
        "</StorageClass>"
    }
    if !rule.delete_data.is_empty() {
      out = out +
        "<DeleteData>" +
        xml_escape(rule.delete_data) +
        "</DeleteData>"
    }
    out = out + "</Destination></Rule>"
  }
  out + "</ReplicationConfiguration>"
}

///|
fn parse_replication(body : String) -> ReplicationConfig {
  let rules : Array[ReplicationRule] = []
  for section in xml_sections(body, "Rule") {
    let destination = match xml_section_of(section, "Destination") {
      Some(text) => text
      None => ""
    }
    rules.push(ReplicationRule::{
      id: xml_first(section, "ID").unwrap_or(""),
      prefix: xml_first(section, "Prefix").unwrap_or(""),
      status: xml_first(section, "Status").unwrap_or(""),
      destination_bucket: xml_first(destination, "Bucket").unwrap_or(""),
      storage_class: xml_first(destination, "StorageClass").unwrap_or(""),
      delete_data: xml_first(destination, "DeleteData").unwrap_or(""),
      historical_object_replication: xml_first(
        section, "HistoricalObjectReplication",
      ).unwrap_or(""),
    })
  }
  ReplicationConfig::{ agency: xml_first(body, "Agency").unwrap_or(""), rules, }
}
