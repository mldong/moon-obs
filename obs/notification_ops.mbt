///|
/// 事件通知：`GET/PUT /?notification`。华为 OBS 的通知配置根是
/// `NotificationConfiguration`，每条 `TopicConfiguration` 带 Id／Filter（Object 下的
/// FilterRule，常用 prefix/suffix）／Topic／Event（可多条）
/// （官方 Python `convertor.py:780-820` 与 `1852`，2026-10-22 现读）。
/// FunctionGraph 那一路不在这批。
pub(all) struct TopicNotification {
  id : String
  filter_prefix : String
  filter_suffix : String
  topic : String
  events : Array[String]
}

///|
pub(all) struct NotificationConfig {
  topics : Array[TopicNotification]
}

///|
pub fn TopicNotification::new(
  id : String,
  topic : String,
  events : Array[String],
  filter_prefix~ : String = "",
  filter_suffix~ : String = "",
) -> TopicNotification {
  TopicNotification::{ id, filter_prefix, filter_suffix, topic, events, }
}

///|
pub async fn Client::put_bucket_notification(
  self : Client,
  bucket : String,
  config : NotificationConfig,
) -> Unit raise @error.ObsError {
  for rule in config.topics {
    if rule.topic.is_empty() {
      raise @error.BadParam("notification rule without a topic: " + rule.id)
    }
    if rule.events.is_empty() {
      raise @error.BadParam("notification rule without events: " + rule.id)
    }
  }
  let document = notification_document(config)
  let response = request(
    self,
    "PUT",
    bucket,
    query=[("notification", "")],
    extra_headers=[("content-type", "application/xml")],
    body=@transport.RequestBody::Bytes(@utf8.encode(document.view())),
  )
  discard_body(response)
}

///|
pub async fn Client::get_bucket_notification(
  self : Client,
  bucket : String,
) -> NotificationConfig raise @error.ObsError {
  let response = request(self, "GET", bucket, query=[("notification", "")]) catch {
    err =>
      match err {
        @error.ObsError::Service(details) =>
          if details.status == 404 {
            return NotificationConfig::{ topics: [], }
          } else {
            raise err
          }
        _ => raise err
      }
  }
  let body = response_body_text(response.body, response.status)
  parse_notification(body)
}

///|
fn notification_document(config : NotificationConfig) -> String {
  let mut out = "<NotificationConfiguration>"
  for rule in config.topics {
    out = out + "<TopicConfiguration><Id>" + xml_escape(rule.id) + "</Id>"
    if !rule.filter_prefix.is_empty() || !rule.filter_suffix.is_empty() {
      out = out + "<Filter><Object>"
      if !rule.filter_prefix.is_empty() {
        out = out +
          "<FilterRule><Name>prefix</Name><Value>" +
          xml_escape(rule.filter_prefix) +
          "</Value></FilterRule>"
      }
      if !rule.filter_suffix.is_empty() {
        out = out +
          "<FilterRule><Name>suffix</Name><Value>" +
          xml_escape(rule.filter_suffix) +
          "</Value></FilterRule>"
      }
      out = out + "</Object></Filter>"
    }
    out = out + "<Topic>" + xml_escape(rule.topic) + "</Topic>"
    for event in rule.events {
      out = out + "<Event>" + xml_escape(event) + "</Event>"
    }
    out = out + "</TopicConfiguration>"
  }
  out + "</NotificationConfiguration>"
}

///|
fn parse_notification(body : String) -> NotificationConfig {
  let topics : Array[TopicNotification] = []
  for section in xml_sections(body, "TopicConfiguration") {
    let filter = match xml_section_of(section, "Filter") {
      Some(text) => text
      None => ""
    }
    topics.push(TopicNotification::{
      id: xml_first(section, "Id").unwrap_or(""),
      topic: xml_first(section, "Topic").unwrap_or(""),
      events: xml_all(section, "Event"),
      filter_prefix: filter_value(filter, "prefix"),
      filter_suffix: filter_value(filter, "suffix"),
    })
  }
  NotificationConfig::{ topics, }
}

///|
fn filter_value(filter : String, want : String) -> String {
  let mut out = ""
  for rule in xml_sections(filter, "FilterRule") {
    if xml_first(rule, "Name") == Some(want) {
      out = xml_first(rule, "Value").unwrap_or("")
    }
  }
  out
}
