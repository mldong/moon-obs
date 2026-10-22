///|
test "replication document writes agency and destination" {
  let config = ReplicationConfig::{
    agency: "obs-replication-agency",
    rules: [
      ReplicationRule::{
        id: "r1",
        prefix: "img/",
        status: "Enabled",
        destination_bucket: "dst-bucket",
        storage_class: "STANDARD",
        delete_data: "Enabled",
        historical_object_replication: "Enabled",
      },
    ],
  }
  assert_eq(
    replication_document(config),
    "<ReplicationConfiguration><Agency>obs-replication-agency</Agency>" +
    "<Rule><ID>r1</ID><Prefix>img/</Prefix><Status>Enabled</Status>" +
    "<HistoricalObjectReplication>Enabled</HistoricalObjectReplication>" +
    "<Destination><Bucket>dst-bucket</Bucket><StorageClass>STANDARD</StorageClass>" +
    "<DeleteData>Enabled</DeleteData></Destination></Rule></ReplicationConfiguration>",
  )
}

///|
test "replication parse reads agency and rule extensions" {
  let body = "<ReplicationConfiguration><Agency>ag</Agency><Rule><ID>a</ID>" +
    "<Prefix></Prefix><Status>Enabled</Status>" +
    "<HistoricalObjectReplication>Disabled</HistoricalObjectReplication>" +
    "<Destination><Bucket>dst</Bucket><StorageClass>WARM</StorageClass>" +
    "<DeleteData>Disabled</DeleteData></Destination></Rule></ReplicationConfiguration>"
  let config = parse_replication(body)
  assert_eq(config.agency, "ag")
  assert_eq(config.rules.length(), 1)
  assert_eq(config.rules[0].storage_class, "WARM")
  assert_eq(config.rules[0].delete_data, "Disabled")
  assert_eq(config.rules[0].historical_object_replication, "Disabled")
}
