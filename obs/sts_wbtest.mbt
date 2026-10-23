///|
test "presigned URLs carry the sts token in the signed query" {
  let credentials = @auth.Credentials::new("ak", "sk").with_security_token(
    "token-1",
  )
  let config = @config.Config::new(
    "obs.cn-north-4.myhuaweicloud.com", "cn-north-4", credentials,
  )
  let client = Client::new(config, @transport.AsyncHttpTransport::new())
  let url = client.presigned_get_url("b", "k") catch {
    _ => abort("presign must work with an sts token")
  }
  assert_true(url.contains("token-1"))
}
