///|
fn tm_client() -> Client raise @error.ObsError {
  let credentials = @auth.Credentials::new("ak", "sk")
  let config = @config.Config::new(
    "obs.cn-north-4.myhuaweicloud.com", "cn-north-4", credentials,
  )
  Client::new(config, @transport.AsyncHttpTransport::new())
}

///|
test "transfer manager seeds empty state and restores a given state" {
  let client = tm_client() catch { _ => abort("client must build") }
  let fresh = TransferManager::new(
    client,
    "b",
    part_size=102400,
    threshold=102400,
  )
  assert_eq(fresh.state().upload_id, "")
  let saved = TransferState::{
    upload_id: "upload-1",
    offset: 204800,
    parts: [(1, "etag-a"), (2, "etag-b")],
  }
  let restored = TransferManager::restore(client, "b", saved)
  assert_eq(restored.state().upload_id, "upload-1")
  assert_eq(restored.state().offset, 204800)
  assert_eq(restored.state().parts.length(), 2)
}
