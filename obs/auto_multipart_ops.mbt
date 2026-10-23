///|
/// 一条式上传：小于等于 `threshold` 走单发 PUT，否则自动切分片并合完。
/// OBS 的非末片最小 100 KiB；分片失败时尽力 abort 再抛原错。
pub async fn Client::put_bytes_auto(
  self : Client,
  bucket : String,
  key : String,
  data : Bytes,
  part_size~ : Int32 = 8388608,
  threshold~ : Int32 = 8388608,
  content_type~ : String = "",
  compute_md5~ : Bool = false,
) -> PutObjectResult raise @error.ObsError {
  if part_size <= 0 || threshold <= 0 {
    raise @error.BadParam("part_size and threshold must be positive")
  }
  if part_size < 102400 {
    raise @error.BadParam("OBS part_size must be at least 102400 bytes")
  }
  if data.length() <= threshold {
    return self.put_object(bucket, key, data, content_type~, compute_md5~)
  }
  let upload_id = self.create_multipart_upload(bucket, key, content_type~)
  let parts : Array[(Int32, String)] = []
  let outcome : Result[String, @error.ObsError] = try {
    let mut offset = 0
    let mut part_number = 1
    while offset < data.length() {
      let end = if offset + part_size < data.length() {
        offset + part_size
      } else {
        data.length()
      }
      let part_etag = self.upload_part(
        bucket,
        key,
        upload_id,
        part_number,
        data[offset:end].to_owned(),
      )
      parts.push((part_number, part_etag))
      part_number = part_number + 1
      offset = end
    }
    Ok(self.complete_multipart_upload(bucket, key, upload_id, parts))
  } catch {
    err => {
      let _ = self.abort_multipart_upload(bucket, key, upload_id) catch {
        _ => ()
      }
      Err(err)
    }
  }
  match outcome {
    Ok(etag) => PutObjectResult::{ etag, }
    Err(err) => raise err
  }
}
