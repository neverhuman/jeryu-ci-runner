//! Bounded static ELF64 inspection. Staged programs and loaders are never run.
use super::{RunnerResult, denied};
use serde::{Deserialize, Serialize};
use std::{fs::File, os::unix::fs::FileExt};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Elf {
    pub kind: u16,
    pub interpreter: Option<String>,
    pub needed: Vec<String>,
    pub soname: Option<String>,
    pub rpath: Option<String>,
    pub runpath: Option<String>,
}

fn invalid() -> jeryu_runner_core::RunnerError {
    denied("image_loader_closure_invalid")
}

fn bytes(file: &File, offset: u64, count: usize, length: u64) -> RunnerResult<Vec<u8>> {
    if count > 16 << 20
        || offset
            .checked_add(count as u64)
            .is_none_or(|end| end > length)
    {
        return Err(invalid());
    }
    let mut bytes = vec![0; count];
    file.read_exact_at(&mut bytes, offset)
        .map_err(|_| invalid())?;
    Ok(bytes)
}
fn u16_at(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(bytes[at..at + 2].try_into().expect("fixed ELF field"))
}
fn u64_at(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().expect("fixed ELF field"))
}
fn string(bytes: &[u8], offset: usize) -> RunnerResult<String> {
    let tail = bytes.get(offset..).ok_or_else(invalid)?;
    let end = tail
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(invalid)?;
    if end == 0 || end > 4096 {
        return Err(invalid());
    }
    let value = std::str::from_utf8(&tail[..end]).map_err(|_| invalid())?;
    if value.bytes().any(|byte| byte.is_ascii_control()) {
        return Err(invalid());
    }
    Ok(value.into())
}

pub(super) fn inspect(file: &File, machine: u16) -> RunnerResult<Option<Elf>> {
    let length = file.metadata()?.len();
    if length < 4 {
        return Ok(None);
    }
    if bytes(file, 0, 4, length)? != b"\x7fELF" {
        return Ok(None);
    }
    let header = bytes(file, 0, 64, length)?;
    let kind = u16_at(&header, 16);
    if header[4..7] != [2, 1, 1]
        || !matches!(header[7], 0 | 3)
        || header[20..24] != [1, 0, 0, 0]
        || !matches!(kind, 1..=3)
        || u16_at(&header, 18) != machine
        || u16_at(&header, 52) != 64
    {
        return Err(invalid());
    }
    let count = usize::from(u16_at(&header, 56));
    if count > 256 || (count != 0 && u16_at(&header, 54) != 56) {
        return Err(invalid());
    }
    let table = bytes(file, u64_at(&header, 32), count * 56, length)?;
    let mut loads = Vec::new();
    let mut interpreter = None;
    let mut dynamic = None;
    for entry in table.chunks_exact(56) {
        let typ = u32::from_le_bytes(entry[..4].try_into().expect("fixed ELF field"));
        let offset = u64_at(entry, 8);
        let address = u64_at(entry, 16);
        let size = u64_at(entry, 32);
        if offset.checked_add(size).is_none_or(|end| end > length) {
            return Err(invalid());
        }
        match typ {
            1 => loads.push((address, offset, size)),
            2 => {
                if dynamic.replace((offset, size)).is_some() {
                    return Err(invalid());
                }
            }
            3 => {
                if interpreter.is_some() || size > 4097 {
                    return Err(invalid());
                }
                let value = bytes(file, offset, size as usize, length)?;
                let path = string(&value, 0)?;
                if value.len() != path.len() + 1 || !path.starts_with('/') {
                    return Err(invalid());
                }
                interpreter = Some(path);
            }
            _ => (),
        }
    }
    let mut result = Elf {
        kind,
        interpreter,
        needed: Vec::new(),
        soname: None,
        rpath: None,
        runpath: None,
    };
    let Some((offset, size)) = dynamic else {
        return Ok(Some(result));
    };
    if size > 65536 || size % 16 != 0 {
        return Err(invalid());
    }
    let dynamic = bytes(file, offset, size as usize, length)?;
    let mut table_address = None;
    let mut table_size = None;
    let mut needed = Vec::new();
    let mut soname = None;
    let mut rpath = None;
    let mut runpath = None;
    let mut terminated = false;
    for entry in dynamic.chunks_exact(16) {
        let tag = u64_at(entry, 0);
        let value = u64_at(entry, 8);
        match tag {
            0 => {
                terminated = true;
                break;
            }
            1 => needed.push(value),
            5 => {
                if table_address.replace(value).is_some() {
                    return Err(invalid());
                }
            }
            10 => {
                if table_size.replace(value).is_some() {
                    return Err(invalid());
                }
            }
            14 => {
                if soname.replace(value).is_some() {
                    return Err(invalid());
                }
            }
            15 => {
                if rpath.replace(value).is_some() {
                    return Err(invalid());
                }
            }
            29 => {
                if runpath.replace(value).is_some() {
                    return Err(invalid());
                }
            }
            _ => (),
        }
    }
    if !terminated {
        return Err(invalid());
    }
    if needed.is_empty() && soname.is_none() && rpath.is_none() && runpath.is_none() {
        return Ok(Some(result));
    }
    let address = table_address.ok_or_else(invalid)?;
    let size = table_size
        .filter(|size| *size <= 16 << 20)
        .ok_or_else(invalid)?;
    let mut matches = loads.into_iter().filter_map(|(start, offset, bytes)| {
        let delta = address.checked_sub(start)?;
        if delta.checked_add(size)? > bytes {
            return None;
        }
        offset.checked_add(delta)
    });
    let offset = matches.next().ok_or_else(invalid)?;
    if matches.next().is_some() {
        return Err(invalid());
    }
    let strings = bytes(file, offset, size as usize, length)?;
    for offset in needed {
        let name = string(&strings, usize::try_from(offset).map_err(|_| invalid())?)?;
        if name.contains('/') || result.needed.contains(&name) {
            return Err(invalid());
        }
        result.needed.push(name);
    }
    result.needed.sort();
    result.soname = soname
        .map(|offset| string(&strings, usize::try_from(offset).map_err(|_| invalid())?))
        .transpose()?;
    result.rpath = rpath
        .map(|offset| string(&strings, usize::try_from(offset).map_err(|_| invalid())?))
        .transpose()?;
    result.runpath = runpath
        .map(|offset| string(&strings, usize::try_from(offset).map_err(|_| invalid())?))
        .transpose()?;
    Ok(Some(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn needed_libraries_and_search_paths_are_read_from_bounded_load_segments() {
        let mut bytes = vec![0u8; 512];
        bytes[..7].copy_from_slice(b"\x7fELF\x02\x01\x01");
        bytes[20..24].copy_from_slice(&1u32.to_le_bytes());
        for (at, value) in [(16, 3u16), (18, 62), (52, 64), (54, 56), (56, 2)] {
            bytes[at..at + 2].copy_from_slice(&value.to_le_bytes());
        }
        bytes[32..40].copy_from_slice(&64u64.to_le_bytes());
        bytes[64..68].copy_from_slice(&1u32.to_le_bytes());
        bytes[80..88].copy_from_slice(&0x400000u64.to_le_bytes());
        bytes[96..104].copy_from_slice(&512u64.to_le_bytes());
        bytes[120..124].copy_from_slice(&2u32.to_le_bytes());
        bytes[128..136].copy_from_slice(&200u64.to_le_bytes());
        bytes[152..160].copy_from_slice(&96u64.to_le_bytes());
        let strings = b"libc.so.6\0libexample.so\0$ORIGIN/../lib\0";
        bytes[320..320 + strings.len()].copy_from_slice(strings);
        for (index, (tag, value)) in [
            (5u64, 0x400140u64),
            (10, strings.len() as u64),
            (1, 0),
            (14, 10),
            (29, 24),
            (0, 0),
        ]
        .into_iter()
        .enumerate()
        {
            let at = 200 + index * 16;
            bytes[at..at + 8].copy_from_slice(&tag.to_le_bytes());
            bytes[at + 8..at + 16].copy_from_slice(&value.to_le_bytes());
        }
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(&bytes).unwrap();
        let elf = inspect(&file, 62).unwrap().unwrap();
        assert_eq!(elf.needed, ["libc.so.6"]);
        assert_eq!(elf.soname.as_deref(), Some("libexample.so"));
        assert_eq!(elf.runpath.as_deref(), Some("$ORIGIN/../lib"));
        bytes[208..216].copy_from_slice(&u64::MAX.to_le_bytes());
        file.write_all_at(&bytes, 0).unwrap();
        assert!(inspect(&file, 62).is_err());
    }
    #[test]
    fn interpreter_is_inspected_without_execution_and_malformed_headers_fail() {
        let mut bytes = vec![0u8; 160];
        bytes[..7].copy_from_slice(b"\x7fELF\x02\x01\x01");
        bytes[20..24].copy_from_slice(&1u32.to_le_bytes());
        bytes[16..18].copy_from_slice(&2u16.to_le_bytes());
        bytes[18..20].copy_from_slice(&62u16.to_le_bytes());
        bytes[32..40].copy_from_slice(&64u64.to_le_bytes());
        bytes[52..54].copy_from_slice(&64u16.to_le_bytes());
        bytes[54..56].copy_from_slice(&56u16.to_le_bytes());
        bytes[56..58].copy_from_slice(&1u16.to_le_bytes());
        bytes[64..68].copy_from_slice(&3u32.to_le_bytes());
        bytes[72..80].copy_from_slice(&120u64.to_le_bytes());
        let path = b"/lib64/ld-linux-x86-64.so.2\0";
        bytes[96..104].copy_from_slice(&(path.len() as u64).to_le_bytes());
        bytes[120..120 + path.len()].copy_from_slice(path);
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(&bytes).unwrap();
        assert_eq!(
            inspect(&file, 62).unwrap().unwrap().interpreter.as_deref(),
            Some("/lib64/ld-linux-x86-64.so.2")
        );
        assert!(inspect(&file, 183).is_err());
        bytes[72..80].copy_from_slice(&u64::MAX.to_le_bytes());
        file.write_all_at(&bytes, 0).unwrap();
        assert!(inspect(&file, 62).is_err());
    }
}
