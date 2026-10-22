///|
test "quota document writes StorageQuota" {
  assert_eq(
    quota_document(1073741824L),
    "<Quota><StorageQuota>1073741824</StorageQuota></Quota>",
  )
}

///|
test "optional int64 parser keeps absent values absent" {
  assert_eq(parse_optional_int64(None), None)
  assert_eq(parse_optional_int64(Some("")), None)
  assert_eq(parse_optional_int64(Some("42")), Some(42L))
}
