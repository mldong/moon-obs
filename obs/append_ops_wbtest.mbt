///|
test "append query and next-position header" {
  assert_eq(append_query(5L)[1].1, "5")
  let headers = [
    @transport.Header::{ name: "x-amz-next-append-position", value: "5", },
  ]
  assert_eq(header_int64(headers, "x-amz-next-append-position"), Some(5L))
}
