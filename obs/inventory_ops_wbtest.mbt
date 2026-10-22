///|
test "inventory document writes OBS flat destination" {
  let config = InventoryConfig::{
    id: "weekly",
    is_enabled: true,
    format: "CSV",
    destination_bucket: "dst-bucket",
    destination_prefix: "reports/",
    frequency: "Weekly",
    included_versions: "All",
    filter_prefix: "logs/",
    optional_fields: ["Size", "ETag"],
  }
  assert_eq(
    inventory_document(config),
    "<InventoryConfiguration><Id>weekly</Id><IsEnabled>true</IsEnabled>" +
    "<Filter><Prefix>logs/</Prefix></Filter>" +
    "<Destination><Format>CSV</Format><Bucket>dst-bucket</Bucket>" +
    "<Prefix>reports/</Prefix></Destination>" +
    "<Schedule><Frequency>Weekly</Frequency></Schedule>" +
    "<IncludedObjectVersions>All</IncludedObjectVersions>" +
    "<OptionalFields><Field>Size</Field><Field>ETag</Field></OptionalFields>" +
    "</InventoryConfiguration>",
  )
}

///|
test "inventory parse reads OBS flat destination" {
  let body = "<InventoryConfiguration><Id>weekly</Id><IsEnabled>false</IsEnabled>" +
    "<Destination><Format>CSV</Format><Bucket>dst</Bucket><Prefix>p/</Prefix></Destination>" +
    "<Schedule><Frequency>Daily</Frequency></Schedule>" +
    "<IncludedObjectVersions>Current</IncludedObjectVersions>" +
    "<OptionalFields><Field>Size</Field></OptionalFields></InventoryConfiguration>"
  let config = parse_inventory(body)
  assert_eq(config.id, "weekly")
  assert_eq(config.is_enabled, false)
  assert_eq(config.destination_bucket, "dst")
  assert_eq(config.destination_prefix, "p/")
  assert_eq(config.frequency, "Daily")
  assert_eq(config.optional_fields, ["Size"])
}

///|
test "inventory list parse splits OBS configurations" {
  let body = "<ListInventoryConfigurationsResult>" +
    "<InventoryConfiguration><Id>a</Id><IsEnabled>true</IsEnabled></InventoryConfiguration>" +
    "<InventoryConfiguration><Id>b</Id><IsEnabled>false</IsEnabled></InventoryConfiguration>" +
    "</ListInventoryConfigurationsResult>"
  let configs = parse_inventories(body)
  assert_eq(configs.length(), 2)
  assert_eq(configs[1].id, "b")
}
