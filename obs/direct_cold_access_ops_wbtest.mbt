///|
test "direct cold access document writes the status" {
  assert_eq(
    direct_cold_access_document("Enabled"),
    "<DirectColdAccessConfiguration><Status>Enabled</Status>" +
    "</DirectColdAccessConfiguration>",
  )
}
