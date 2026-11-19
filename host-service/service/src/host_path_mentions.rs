//! 訊息文字中的主機絕對路徑辨識(#229)。與 app 的 `HostPathMention` 規則相同，兩端共用
//! `protocol/host-path-mentions.json` 的案例;以 Unicode scalar 逐一比對(Swift 端也是)。
//!
//! - POSIX(`/` 開頭、至少兩段)與 Windows 磁碟機路徑;不含 `.`／`..`、空段落，結尾不是分隔符號。
//! - 一般文字裡的路徑到空白或標點為止，前面要接空白、標點或非 ASCII 文字;句尾標點與 `:行號` 不算。
//! - 含空白的路徑要整段包在反引號或引號裡;行內 code 與程式碼區塊只在整段是路徑時才算。

/// 一般文字中的路徑在這些字元前結束。
const TERMINATORS: &str = "`\"'<>|*[]{},;:「」『』（）【】《》〈〉“”‘’，。、；：！？";

/// 路徑前面接這些字元時不算開頭(例如 `a/b`、`https://`、`~/`、`./`)。
const CONTINUATIONS: &str = "/\\.~-_$%@+&#";

const QUOTE_PAIRS: [(char, char); 4] = [('"', '"'), ('“', '”'), ('「', '」'), ('『', '』')];

/// 文字中認得的主機路徑，依出現順序。
pub fn paths(text: &str) -> Vec<String> {
    let scalars: Vec<char> = text.chars().collect();
    let mut found = Vec::new();
    let mut position = 0;
    while position < scalars.len() {
        let scalar = scalars[position];
        if scalar == '`' {
            let run = run_length('`', &scalars, position);
            let Some(close) = closing_run(run, &scalars, position + run) else {
                position += run;
                continue;
            };
            let mut content: String = scalars[position + run..close].iter().collect();
            if content.chars().count() >= 2 && content.starts_with(' ') && content.ends_with(' ') && content.chars().any(|c| c != ' ') {
                content = content[1..content.len() - 1].to_owned();
            }
            if let Some(path) = delimited_path(&content) {
                found.push(path);
            }
            position = close + run;
            continue;
        }
        if let Some(&(_, closing)) = QUOTE_PAIRS.iter().find(|(opening, _)| *opening == scalar)
            && let Some(offset) = scalars[position + 1..].iter().position(|&c| c == closing || c == '\n')
            && scalars[position + 1 + offset] == closing
            && let Some(path) = delimited_path(&scalars[position + 1..position + 1 + offset].iter().collect::<String>())
        {
            found.push(path);
            position += offset + 2;
            continue;
        }
        if let Some(end) = bare_end(&scalars, position) {
            let candidate: String = scalars[position..end].iter().collect();
            if is_host_path(&candidate, false) {
                found.push(candidate);
                position = end;
                continue;
            }
        }
        position += 1;
    }
    found
}

fn run_length(scalar: char, scalars: &[char], position: usize) -> usize {
    scalars[position..].iter().take_while(|&&c| c == scalar).count()
}

/// 長度剛好是 `run` 的下一串反引號的開頭。
fn closing_run(run: usize, scalars: &[char], start: usize) -> Option<usize> {
    let mut search = start;
    while search < scalars.len() {
        if scalars[search] != '`' {
            search += 1;
            continue;
        }
        let length = run_length('`', scalars, search);
        if length == run {
            return Some(search);
        }
        search += length;
    }
    None
}

/// 從 `position` 開始的一般文字路徑的結尾;這裡不是路徑開頭時 `None`。
fn bare_end(scalars: &[char], position: usize) -> Option<usize> {
    if position > 0 {
        let previous = scalars[position - 1];
        if previous.is_ascii_alphanumeric() || CONTINUATIONS.contains(previous) {
            return None;
        }
    }
    let is_windows =
        position + 2 < scalars.len() && scalars[position].is_ascii_alphabetic() && scalars[position + 1] == ':' && matches!(scalars[position + 2], '\\' | '/');
    if !is_windows && scalars[position] != '/' {
        return None;
    }
    let mut end = if is_windows { position + 2 } else { position };
    while end < scalars.len() && !is_terminator(scalars[end]) {
        end += 1;
    }
    while end > position {
        let last = scalars[end - 1];
        let opening = scalars[position..end].iter().filter(|&&c| c == '(').count();
        let closing = scalars[position..end].iter().filter(|&&c| c == ')').count();
        if !(matches!(last, '.' | '!' | '?') || (last == ')' && closing > opening)) {
            break;
        }
        end -= 1;
    }
    Some(end)
}

fn is_terminator(scalar: char) -> bool {
    scalar.is_whitespace() || scalar.is_control() || TERMINATORS.contains(scalar)
}

/// 包起來的整段：去掉結尾的 `:行號`(與 `:欄`)後是主機路徑(可含空白)。
fn delimited_path(content: &str) -> Option<String> {
    let path = strip_line_suffix(content);
    is_host_path(path, true).then(|| path.to_owned())
}

/// 去掉結尾的 `:數字` 或 `:數字:數字`。
fn strip_line_suffix(content: &str) -> &str {
    fn strip_number(text: &str) -> Option<&str> {
        let digits = text.len() - text.trim_end_matches(|c: char| c.is_ascii_digit()).len();
        if digits == 0 {
            return None;
        }
        text[..text.len() - digits].strip_suffix(':')
    }
    match strip_number(content) {
        Some(once) => strip_number(once).unwrap_or(once),
        None => content,
    }
}

/// 整段是一個主機絕對路徑。
fn is_host_path(candidate: &str, allows_spaces: bool) -> bool {
    if candidate.is_empty() || candidate.starts_with(' ') || candidate.ends_with(' ') {
        return false;
    }
    if candidate.chars().any(|c| (c.is_control() || c.is_whitespace()) && !(allows_spaces && c == ' ')) {
        return false;
    }
    let bytes = candidate.as_bytes();
    let is_windows = bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && matches!(bytes[2], b'\\' | b'/');
    let (components, minimum): (Vec<&str>, usize) = if is_windows {
        if candidate[2..].contains(['<', '>', ':', '"', '|', '?', '*']) {
            return false;
        }
        (candidate[3..].split(['\\', '/']).collect(), 1)
    } else if let Some(rest) = candidate.strip_prefix('/') {
        (rest.split('/').collect(), 2)
    } else {
        return false;
    };
    components.len() >= minimum
        && components
            .iter()
            .all(|component| !component.is_empty() && *component != "." && *component != ".." && !component.contains(':'))
}
