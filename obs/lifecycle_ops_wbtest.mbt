///|
test "lifecycle document writes the OBS abort element" {
  let rules = [
    LifecycleRule::new("expire-logs", prefix="logs/")
    .with_expiration(days=Some(30))
    .with_transitions([
      LifecycleTransition::{
        days: Some(7),
        date: None,
        storage_class: "STANDARD_IA",
      },
    ])
    .with_abort_multipart(3),
  ]
  assert_eq(
    lifecycle_document(rules),
    "<LifecycleConfiguration><Rule><ID>expire-logs</ID><Prefix>logs/</Prefix>" +
    "<Status>Enabled</Status><Expiration><Days>30</Days></Expiration>" +
    "<Transition><Days>7</Days><StorageClass>STANDARD_IA</StorageClass></Transition>" +
    "<AbortIncompleteMultipartUpload><DaysAfterInitiation>3</DaysAfterInitiation>" +
    "</AbortIncompleteMultipartUpload></Rule></LifecycleConfiguration>",
  )
}

///|
test "lifecycle parse reads expiration, abort and noncurrent days" {
  let sample = "<LifecycleConfiguration><Rule><ID>a</ID><Prefix>logs/</Prefix><Status>Enabled</Status>" +
    "<Expiration><Days>10</Days><ExpiredObjectDeleteMarker>false</ExpiredObjectDeleteMarker></Expiration>" +
    "<Transition><Days>5</Days><StorageClass>ARCHIVE</StorageClass></Transition>" +
    "<AbortIncompleteMultipartUpload><DaysAfterInitiation>2</DaysAfterInitiation>" +
    "</AbortIncompleteMultipartUpload>" +
    "<NoncurrentVersionExpiration><NoncurrentDays>20</NoncurrentDays></NoncurrentVersionExpiration>" +
    "</Rule><Rule><ID>b</ID><Prefix>tmp/</Prefix><Status>Disabled</Status>" +
    "<Expiration><Date>2027-01-01T00:00:00.000Z</Date></Expiration></Rule></LifecycleConfiguration>"
  let rules = parse_lifecycle_rules(sample)
  assert_eq(rules.length(), 2)
  assert_eq(rules[0].prefix, "logs/")
  assert_eq(rules[0].expiration_days, Some(10))
  assert_eq(rules[0].transitions[0].storage_class, "ARCHIVE")
  assert_eq(rules[0].abort_incomplete_multipart_days, Some(2))
  assert_eq(rules[0].noncurrent_version_expiration_days, Some(20))
  assert_eq(rules[1].status, "Disabled")
  assert_eq(rules[1].expiration_date, Some("2027-01-01T00:00:00.000Z"))
}

///|
test "lifecycle parse accepts the OSS abort element name too" {
  let sample = "<LifecycleConfiguration><Rule><ID>c</ID><Prefix></Prefix><Status>Enabled</Status>" +
    "<AbortMultipartUpload><Days>4</Days></AbortMultipartUpload></Rule></LifecycleConfiguration>"
  let rules = parse_lifecycle_rules(sample)
  assert_eq(rules.length(), 1)
  assert_eq(rules[0].abort_incomplete_multipart_days, Some(4))
}
