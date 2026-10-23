///|
test "presigned URLs reject sts credentials instead of dropping the token" {
  let credentials = @auth.Credentials::new("ak", "sk").with_security_token(
    "token-1",
  )
  let config = @config.Config::new(
    "obs.cn-north-4.myhuaweicloud.com", "cn-north-4", credentials,
  )
  let client = Client::new(config, @transport.AsyncHttpTransport::new())
  let mut rejected = false
  let _ = client.presigned_get_url("b", "k") catch {
    @error.ObsError::BadParam(_) => {
      rejected = true
      ""
    }
    _ => ""
  }
  assert_true(rejected)
}
