///|
/// OBS 回体的 XML 读数件。
///
/// 为什么这一份不能照抄隔壁的形状：**OBS 的 XML 全带命名空间**
/// （真桶读数：`<ListBucketResult xmlns="http://obs.myhwclouds.com/doc/2015-06-30/">`），
/// 而 ACL 回体里 `<Grantee>` 还挂着 `xmlns:xsi`／`xsi:type` 两个属性。
/// 按 `<Tag>` 整串匹配的解析器会把这两处都读成"字段不存在"——那是解析件的错，
/// 不是服务端的错，却会被汇报成"OBS 不返回 grant"。所以这里一律**按局部名匹配**：
/// 名字取 `<` 之后到空白／`/`／`>` 为止，去掉 `前缀:`，属性从开始标签里单独拆出来。
///
/// 一条纪律：**读不到就是 `None`（或空数组），不静默给空值**。列举回包里少一个 `<Key>`
/// 与"这个桶是空的"是两件事，混成一件就只能靠人肉看响应体。
///
/// 已知不处理的形状（写在这里而不是装作不存在）：注释与处理指令整段跳过；
/// 同名元素**嵌套**时只认最外层。

///|
/// 一处元素的读数。`attrs` 是开始标签里名字之后、定界符之前的原文，
/// 命名空间声明就落在这里——读 `xsi:type` 这类"拼法信息"靠它，不靠猜标签名。
pub(all) struct XmlElement {
  /// 内部文本（未做实体还原；要还原走 [xml_all]／[xml_first]）
  content : String
  /// 开始标签的属性原文，如 `xmlns:xsi="…" xsi:type="Group"`
  attrs : String
  /// `<Tag/>` 这种空元素：内容是空串，但**它存在**，与"读不到"是两件事
  self_closing : Bool
}

///|
/// 命中位置（下标都是 [Char] 数组坐标，不外露）。
priv struct Hit {
  content_start : Int32
  content_end : Int32
  attrs_start : Int32
  attrs_end : Int32
  self_closing : Bool
  next : Int32
}

///|
fn is_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
/// 元素名的结束下标：名字止于空白、`/` 或 `>`。
fn name_end(chars : Array[Char], from : Int32) -> Int32 {
  let n = chars.length()
  let mut i = from
  while i < n {
    let c = chars[i]
    if c == '>' || c == '/' || is_space(c) {
      return i
    }
    i = i + 1
  }
  n
}

///|
/// 局部名：`<ns:Tag>` 与 `<Tag>` 都读成 `Tag`（取最后一个冒号之后的部分）。
fn local_name(chars : Array[Char], from : Int32, to : Int32) -> String {
  let mut cut = from
  let mut i = from
  while i < to {
    if chars[i] == ':' {
      cut = i + 1
    }
    i = i + 1
  }
  String::from_array(chars[cut:to])
}

///|
/// 一个 QNames 的局部名（属性名用得上：`xsi:type` 读成 `type`）。
/// 不用 `split`：本版 `String.split` 给的是迭代器，取"最后一段"要倒着扫更直接。
fn local_of(name : String) -> String {
  let chars = name.to_array()
  let mut cut = 0
  let mut i = 0
  while i < chars.length() {
    if chars[i] == ':' {
      cut = i + 1
    }
    i = i + 1
  }
  String::from_array(chars[cut:chars.length()])
}

///|
/// 从属性区起点找到开始标签的定界符：返回 `>` 的下标与"是否自闭合"。
/// 引号里的 `>` 不算定界符（属性值里出现它是合法的）。
fn open_tag_end(chars : Array[Char], from : Int32) -> (Int32, Bool)? {
  let n = chars.length()
  let mut i = from
  // 0 = 不在引号里，1 = 双引号，2 = 单引号
  let mut quote = 0
  while i < n {
    let c = chars[i]
    if quote == 0 && (c == '"' || c == '\'') {
      quote = if c == '"' { 1 } else { 2 }
    } else if (quote == 1 && c == '"') || (quote == 2 && c == '\'') {
      quote = 0
    } else if quote == 0 && c == '>' {
      return Some((i, i > from && chars[i - 1] == '/'))
    }
    i = i + 1
  }
  None
}

///|
/// 结束标签 `</tag>` 的位置：返回**标签起点**（内容到此为止）与名字结束下标。
/// 同名嵌套只认第一处结束标签（文件头写明这一条不处理）。
fn close_tag(
  chars : Array[Char],
  tag : String,
  from : Int32,
) -> (Int32, Int32)? {
  let n = chars.length()
  let mut i = from
  while i < n {
    if chars[i] == '<' && i + 1 < n && chars[i + 1] == '/' {
      let name_at = i + 2
      let end_at = name_end(chars, name_at)
      if end_at > name_at && local_name(chars, name_at, end_at) == tag {
        return Some((i, end_at))
      }
    }
    i = i + 1
  }
  None
}

///|
/// 结束标签的名字之后还有 `>`，下一个搜索要点在它之后。
fn skip_close_tag(chars : Array[Char], name_end_at : Int32) -> Int32 {
  let n = chars.length()
  let mut i = name_end_at
  while i < n && chars[i] != '>' {
    i = i + 1
  }
  i + 1
}

///|
/// 从 `from` 起找第一个局部名为 `tag` 的元素。
fn find_hit(chars : Array[Char], tag : String, from : Int32) -> Hit? {
  let n = chars.length()
  let mut i = from
  while i < n {
    if chars[i] != '<' || i + 1 >= n {
      i = i + 1
    } else {
      let after = chars[i + 1]
      // 注释 / 处理指令 / 结束标签 / 空白名：单步跳过，不当成开始标签
      if after == '!' || after == '?' || after == '/' || is_space(after) {
        i = i + 1
      } else {
        let name_at = i + 1
        let end_at = name_end(chars, name_at)
        match open_tag_end(chars, end_at) {
          None => return None
          Some((gt, self_close)) =>
            if local_name(chars, name_at, end_at) != tag {
              // 不是目标元素：只跳过它的开始标签，继续往**里面**找
              // （`<Contents>` 里嵌着 `<Key>`，整体跳过就会漏）
              i = gt + 1
            } else if self_close {
              return Some(Hit::{
                content_start: gt + 1,
                content_end: gt + 1,
                attrs_start: end_at,
                attrs_end: gt - 1,
                self_closing: true,
                next: gt + 1,
              })
            } else {
              match close_tag(chars, tag, gt + 1) {
                None => return None
                Some((inner_end, close_name_end)) =>
                  return Some(Hit::{
                    content_start: gt + 1,
                    content_end: inner_end,
                    attrs_start: end_at,
                    attrs_end: gt,
                    self_closing: false,
                    next: skip_close_tag(chars, close_name_end),
                  })
              }
            }
        }
      }
    }
  }
  None
}

///|
fn hit_to_element(chars : Array[Char], hit : Hit) -> XmlElement {
  XmlElement::{
    content: String::from_array(chars[hit.content_start:hit.content_end]),
    attrs: String::from_array(chars[hit.attrs_start:hit.attrs_end]),
    self_closing: hit.self_closing,
  }
}

///|
/// 按文档序取每一处局部名为 `tag` 的元素（含属性）。
pub fn xml_elements(text : String, tag : String) -> Array[XmlElement] {
  let chars = text.to_array()
  let out : Array[XmlElement] = []
  let mut cursor = 0
  let mut going = true
  while going {
    match find_hit(chars, tag, cursor) {
      None => going = false
      Some(hit) => {
        out.push(hit_to_element(chars, hit))
        cursor = hit.next
      }
    }
  }
  out
}

///|
/// 第一处局部名为 `tag` 的元素。
pub fn xml_element(text : String, tag : String) -> XmlElement? {
  let chars = text.to_array()
  match find_hit(chars, tag, 0) {
    None => None
    Some(hit) => Some(hit_to_element(chars, hit))
  }
}

///|
/// 属性名比较：**比局部名**（`type` 认 `xsi:type`），且 `xmlns`／`xmlns:xx` 那一族是
/// 命名空间声明、不当业务属性读——否则 `attr("type")` 会误吃到 `xmlns:xsi` 的值。
fn attr_matches(key : String, want : String) -> Bool {
  if key == "xmlns" || key.has_prefix("xmlns:") {
    false
  } else {
    local_of(key) == local_of(want)
  }
}

///|
/// 开始标签上的一个属性读数。
pub fn XmlElement::attr(self : XmlElement, name : String) -> String? {
  let chars = self.attrs.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    if is_space(chars[i]) {
      i = i + 1
    } else {
      let key_at = i
      while i < n && chars[i] != '=' && !is_space(chars[i]) {
        i = i + 1
      }
      let key = String::from_array(chars[key_at:i])
      if i < n && chars[i] == '=' {
        i = i + 1
        let quoted = i < n && (chars[i] == '"' || chars[i] == '\'')
        let marker = if quoted { chars[i] } else { '[' }
        if quoted {
          i = i + 1
        }
        let value_at = i
        if quoted {
          while i < n && chars[i] != marker {
            i = i + 1
          }
          let value = String::from_array(chars[value_at:i])
          if i < n {
            i = i + 1
          }
          if attr_matches(key, name) {
            return Some(xml_unescape(value))
          }
        } else {
          while i < n && !is_space(chars[i]) {
            i = i + 1
          }
          let value = String::from_array(chars[value_at:i])
          if attr_matches(key, name) {
            return Some(xml_unescape(value))
          }
        }
      } else {
        // 无值属性（XML 里非法，但读侧不该因此卡住）
        i = i + 1
      }
    }
  }
  None
}

///|
/// 命名空间声明的读数（`xmlns="…"` 或 `xmlns:xx="…"`）。
/// 业务属性读不到 `xmlns` 那一族（见 [attr_matches]），这一条**专读它们**：
/// "这份回体用的是哪一版协议"本身就是要记录的读数，不该被属性的排除规则一起吃掉。
/// 实现是就地找 `name=` 后的引号串——命名空间 URI 里没有引号，够用。
pub fn XmlElement::ns_decl(self : XmlElement, name : String) -> String? {
  let chars = self.attrs.to_array()
  let n = chars.length()
  let want = name.to_array()
  let w = want.length()
  let mut i = 0
  while i + w <= n {
    let mut k = 0
    while k < w && chars[i + k] == want[k] {
      k = k + 1
    }
    if k == w && i + w < n && chars[i + w] == '=' {
      let mut j = i + w + 1
      if j < n && (chars[j] == '"' || chars[j] == '\'') {
        let quote = chars[j]
        j = j + 1
        let start = j
        while j < n && chars[j] != quote {
          j = j + 1
        }
        return Some(String::from_array(chars[start:j]))
      }
      return None
    }
    i = i + 1
  }
  None
}

///|
/// 按文档序列出所有元素的**局部名**——"字段到底叫什么"这一格靠它读，不靠文档。
pub fn xml_element_names(text : String) -> Array[String] {
  let chars = text.to_array()
  let n = chars.length()
  let out : Array[String] = []
  let mut i = 0
  while i < n {
    if chars[i] != '<' || i + 1 >= n {
      i = i + 1
    } else {
      let after = chars[i + 1]
      if after == '!' || after == '?' || after == '/' || is_space(after) {
        i = i + 1
      } else {
        let name_at = i + 1
        let end_at = name_end(chars, name_at)
        match open_tag_end(chars, end_at) {
          None => return out
          Some((gt, _)) => {
            if end_at > name_at {
              out.push(local_name(chars, name_at, end_at))
            }
            i = gt + 1
          }
        }
      }
    }
  }
  out
}

///|
/// 按文档序取每一处 `<tag>…</tag>` 的内容（已实体还原）。
pub fn xml_all(text : String, tag : String) -> Array[String] {
  let out : Array[String] = []
  for elem in xml_elements(text, tag) {
    out.push(xml_unescape(elem.content))
  }
  out
}

///|
/// 只读第一处内容（已实体还原）。
pub fn xml_first(text : String, tag : String) -> String? {
  match xml_element(text, tag) {
    None => None
    Some(elem) => Some(xml_unescape(elem.content))
  }
}

///|
/// 按父标签切段，返回每一段的**内部原文**（不还原实体，段内还要再取值）。
/// 列举一行要同时读 `Key`／`Size`／`ETag`，先切段再段内取值，才不会把上一段的字段
/// 接到下一段上（`xml_all("Key")` 与 `xml_all("Size")` 各取一次，长度不等时就是错配）。
pub fn xml_sections(text : String, tag : String) -> Array[String] {
  let out : Array[String] = []
  for elem in xml_elements(text, tag) {
    out.push(elem.content)
  }
  out
}

///|
/// 实体还原归 hutool（`@text.unescape_xml`），本仓不再自带那张表。
/// 解不动时整串原样退回——落单代理这类形状 MoonBit 的 `String` 表示不了，
/// 整串拒绝比产出一个装不下的值诚实。
pub fn xml_unescape(text : String) -> String {
  @text.unescape_xml(text) catch {
    _ => text
  }
}

///|
/// 写进 XML 请求体的文本要转义（对象键可以含 `&` 与 `<`）。hutool 的 `escape_xml`
/// 是单趟查表，不会像"逐条 replace_all"那样把刚产出的 `&amp;` 再吃进去。
pub fn xml_escape(text : String) -> String {
  @text.escape_xml(text)
}

///|
/// 错误体里的 `<Code>`，读不出给空串（调用方按空串走"非服务端错"那一档）。
pub fn xml_error_code(body : String) -> String {
  match xml_first(body, "Code") {
    Some(code) => code
    None => ""
  }
}
