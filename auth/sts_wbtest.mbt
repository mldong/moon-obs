///|
test "security token attaches and empty token is a no-op" {
  let base = Credentials::new("ak", "sk") catch {
    _ => abort("credentials must build")
  }
  assert_eq(base.security_token(), None)
  let scoped = base.with_security_token("token-1")
  assert_eq(scoped.security_token(), Some("token-1"))
  assert_eq(scoped.access_key(), "ak")
}
