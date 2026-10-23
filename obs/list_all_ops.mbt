///|
/// 翻页器：V1 形态按 `NextMarker` 翻页；服务端没给 `NextMarker`（不带 delimiter 时
/// 常见）就用本页最后一个键继续。`max_pages` 默认 1000 页；`body` 留最后一页原文。
pub async fn Client::list_all_objects(
  self : Client,
  bucket : String,
  prefix~ : String = "",
  delimiter~ : String = "",
  max_keys~ : Int32 = 1000,
  max_pages~ : Int32 = 1000,
) -> ObjectListing raise @error.ObsError {
  let objects : Array[ObjectInfo] = []
  let prefixes : Array[String] = []
  let mut marker = ""
  let mut pages = 0
  let mut body = ""
  let mut last_truncated = false
  let mut next_marker : String? = None
  while pages < max_pages {
    let page = self.list_objects(
      bucket,
      prefix~,
      delimiter~,
      max_keys~,
      marker~,
    )
    objects.append(page.objects)
    prefixes.append(page.common_prefixes)
    body = page.body
    last_truncated = page.is_truncated
    next_marker = page.next_marker
    pages = pages + 1
    if !page.is_truncated {
      break
    }
    let next = match next_marker {
      Some(value) => if value.is_empty() { "" } else { value }
      None =>
        if page.objects.length() > 0 {
          page.objects[page.objects.length() - 1].key
        } else {
          ""
        }
    }
    if next.is_empty() {
      break
    }
    marker = next
  }
  ObjectListing::{
    objects,
    common_prefixes: prefixes,
    is_truncated: last_truncated,
    next_marker,
    body,
  }
}
