///|
test "notification document writes topic, filters and events" {
  let rule = TopicNotification::{
    id: "notify",
    filter_prefix: "img/",
    filter_suffix: ".jpg",
    topic: "urn:obs:topic:notify",
    events: ["ObjectCreated:Put", "ObjectRemoved:Delete"],
  }
  assert_eq(
    notification_document(NotificationConfig::{ topics: [rule], }),
    "<NotificationConfiguration><TopicConfiguration><Id>notify</Id>" +
    "<Filter><Object><FilterRule><Name>prefix</Name><Value>img/</Value></FilterRule>" +
    "<FilterRule><Name>suffix</Name><Value>.jpg</Value></FilterRule></Object></Filter>" +
    "<Topic>urn:obs:topic:notify</Topic><Event>ObjectCreated:Put</Event>" +
    "<Event>ObjectRemoved:Delete</Event></TopicConfiguration></NotificationConfiguration>",
  )
}

///|
test "notification parse reads topic rules" {
  let body = "<NotificationConfiguration><TopicConfiguration><Id>n</Id>" +
    "<Filter><Object><FilterRule><Name>prefix</Name><Value>logs/</Value></FilterRule>" +
    "</Object></Filter><Topic>urn:obs:topic:t</Topic><Event>ObjectCreated:Put</Event>" +
    "</TopicConfiguration></NotificationConfiguration>"
  let config = parse_notification(body)
  assert_eq(config.topics.length(), 1)
  assert_eq(config.topics[0].id, "n")
  assert_eq(config.topics[0].filter_prefix, "logs/")
  assert_eq(config.topics[0].topic, "urn:obs:topic:t")
  assert_eq(config.topics[0].events, ["ObjectCreated:Put"])
}
