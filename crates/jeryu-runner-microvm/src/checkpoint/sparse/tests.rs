use super::*;
use std::io::Cursor;

fn fixture(bytes: u64, dense: bool) -> File {
    let mut f = tempfile::tempfile().unwrap();
    f.set_len(bytes).unwrap();
    if dense {
        f.write_all(&vec![0; bytes as usize]).unwrap();
    }
    f
}
fn encode(f: &mut File) -> (Vec<u8>, String, String) {
    let mut out = vec![];
    let bytes = f.metadata().unwrap().len();
    let (plain, cipher) = encrypt(f, &mut out, &[7; 32], bytes, b"exact-context").unwrap();
    (out, plain, cipher)
}
fn decode(encoded: &[u8], bytes: u64, binding: &[u8], plain: &str) -> std::io::Result<Vec<u8>> {
    let cipher = format!("sha256:{}", hex::encode(Sha256::digest(encoded)));
    let mut target = fixture(bytes, true);
    target.seek(SeekFrom::Start(0)).unwrap();
    target.write_all(&vec![255; bytes as usize]).unwrap();
    decrypt(
        &mut Cursor::new(encoded),
        &mut target,
        &[7; 32],
        bytes,
        binding,
        plain,
        &cipher,
    )?;
    target.seek(SeekFrom::Start(0))?;
    let mut out = vec![];
    target.read_to_end(&mut out)?;
    Ok(out)
}
fn data(f: &mut File, offset: u64, value: u8, length: usize) {
    f.seek(SeekFrom::Start(offset)).unwrap();
    f.write_all(&vec![value; length]).unwrap();
}

#[test]
fn all_holes_have_an_authenticated_end_and_clear_the_exact_successor() {
    let bytes = 3 * CHUNK + 17;
    let mut f = fixture(bytes, false);
    let (encoded, plain, _) = encode(&mut f);
    assert_eq!(encoded.len(), 56);
    assert_eq!(
        decode(&encoded, bytes, b"exact-context", &plain).unwrap(),
        vec![0; bytes as usize]
    );
    assert!(decode(&encoded, bytes, b"wrong-context", &plain).is_err());
    assert!(
        decode(
            &encoded[..encoded.len() - 1],
            bytes,
            b"exact-context",
            &plain
        )
        .is_err()
    );
    for index in [0, 8, 16, 24, 32, 36, 40, 55] {
        let mut changed = encoded.clone();
        changed[index] ^= 1;
        assert!(
            decode(&changed, bytes, b"exact-context", &plain).is_err(),
            "header/end byte {index}"
        );
    }
    let mut extra = encoded;
    extra.push(0);
    assert!(decode(&extra, bytes, b"exact-context", &plain).is_err());
}

#[test]
fn digest_and_contents_are_independent_of_allocated_zero_extents_and_fallback() {
    let bytes = 3 * CHUNK + 19;
    let mut holes = fixture(bytes, false);
    let mut allocated = fixture(bytes, true);
    for file in [&mut holes, &mut allocated] {
        data(file, CHUNK - 3, 31, 11);
        data(file, 3 * CHUNK + 2, 47, 5);
    }
    let (encoded, plain, _) = encode(&mut holes);
    let (_, allocated_plain, _) = encode(&mut allocated);
    assert_eq!(plain, allocated_plain);
    let mut fallback = vec![];
    let mut calls = 0;
    let (fallback_plain, _) = encrypt_using(
        &mut holes,
        &mut fallback,
        &[7; 32],
        bytes,
        b"exact-context",
        |_, cursor, _| {
            calls += 1;
            if cursor == 0 {
                Ok(Some(0))
            } else {
                Err(std::io::Error::from_raw_os_error(nix::libc::EOPNOTSUPP))
            }
        },
    )
    .unwrap();
    assert!(calls >= 2);
    assert_eq!(
        plain, fallback_plain,
        "fall back after ciphertext without resetting nonces"
    );
    let recovered = decode(&encoded, bytes, b"exact-context", &plain).unwrap();
    let fallback_recovered = decode(&fallback, bytes, b"exact-context", &plain).unwrap();
    holes.seek(SeekFrom::Start(0)).unwrap();
    let mut expected = vec![];
    holes.read_to_end(&mut expected).unwrap();
    assert_eq!(recovered, expected);
    assert_eq!(fallback_recovered, expected);
    assert!(super::super::storage_charge(bytes).unwrap() >= encoded.len() as u64);
    assert!(super::super::storage_charge(u64::MAX).is_err());
    assert!(maximum_size(0).is_err());
    assert!(maximum_size(MAX_BYTES + 1).is_err());
    let mut out = vec![];
    assert!(
        encrypt_using(
            &mut holes,
            &mut out,
            &[7; 32],
            bytes,
            b"exact-context",
            |_, _, _| Err(std::io::Error::from_raw_os_error(nix::libc::EIO))
        )
        .is_err()
    );
}

#[test]
fn descriptors_order_count_payloads_and_context_are_authenticated() {
    let bytes = 2 * CHUNK + 19;
    let mut f = fixture(bytes, false);
    data(&mut f, 0, 11, 1);
    data(&mut f, CHUNK, 13, 1);
    data(&mut f, 2 * CHUNK, 17, 19);
    let (encoded, plain, _) = encode(&mut f);
    let stride = 16 + CHUNK as usize + TAG;
    let second = 24 + stride;
    let end = 24 + 2 * stride + 16 + 19 + TAG;
    assert!(decode(&encoded, bytes, b"wrong-context", &plain).is_err());
    for index in [
        24,
        32,
        36,
        40,
        second,
        second + 8,
        second + 12,
        end,
        end + 8,
        end + 12,
        end + 16,
    ] {
        let mut changed = encoded.clone();
        changed[index] ^= 1;
        assert!(
            decode(&changed, bytes, b"exact-context", &plain).is_err(),
            "mutated byte {index}"
        );
    }
    let mut overlap = encoded.clone();
    overlap[second..second + 8].copy_from_slice(&0_u64.to_be_bytes());
    assert!(decode(&overlap, bytes, b"exact-context", &plain).is_err());
    let mut unaligned = encoded.clone();
    unaligned[24..32].copy_from_slice(&1_u64.to_be_bytes());
    assert!(decode(&unaligned, bytes, b"exact-context", &plain).is_err());
    let mut enormous = encoded.clone();
    enormous[32..36].copy_from_slice(&u32::MAX.to_be_bytes());
    assert!(decode(&enormous, bytes, b"exact-context", &plain).is_err());
    let mut reordered = encoded.clone();
    reordered[24..second].copy_from_slice(&encoded[second..second + stride]);
    reordered[second..second + stride].copy_from_slice(&encoded[24..second]);
    assert!(decode(&reordered, bytes, b"exact-context", &plain).is_err());
    let mut dropped = encoded.clone();
    dropped.drain(24..second);
    assert!(decode(&dropped, bytes, b"exact-context", &plain).is_err());
    let mut duplicate = encoded.clone();
    duplicate.splice(second..second, encoded[24..second].iter().copied());
    assert!(decode(&duplicate, bytes, b"exact-context", &plain).is_err());
    assert!(decode(&encoded[..end], bytes, b"exact-context", &plain).is_err());
    let mut duplicated_end = encoded.clone();
    duplicated_end.extend_from_slice(&encoded[end..]);
    assert!(decode(&duplicated_end, bytes, b"exact-context", &plain).is_err());
    let mut count = encoded.clone();
    count[36..40].copy_from_slice(&u32::MAX.to_be_bytes());
    assert!(decode(&count, bytes, b"exact-context", &plain).is_err());
}

#[test]
fn even_authentic_noncanonical_zero_records_and_wrong_digests_are_refused() {
    let bytes = 19;
    let mut f = fixture(bytes, false);
    data(&mut f, 0, 9, 19);
    let (mut encoded, plain, _) = encode(&mut f);
    let header: [u8; 24] = encoded[..24].try_into().unwrap();
    let meta: [u8; 16] = encoded[24..40].try_into().unwrap();
    let mut zeros = vec![0; 19];
    key(&[7; 32])
        .unwrap()
        .seal_in_place_append_tag(
            nonce(&header, 0),
            aead::Aad::from(record_aad(&associated(&header, b"exact-context"), &meta, 0)),
            &mut zeros,
        )
        .unwrap();
    encoded[40..40 + 19 + TAG].copy_from_slice(&zeros);
    assert!(decode(&encoded, bytes, b"exact-context", &plain).is_err());
    let (encoded, plain, cipher) = encode(&mut f);
    let mut target = fixture(bytes, false);
    assert!(
        decrypt(
            &mut Cursor::new(&encoded),
            &mut target,
            &[7; 32],
            bytes,
            b"exact-context",
            &plain,
            &format!("sha256:{}", "0".repeat(64))
        )
        .is_err()
    );
    assert!(
        decrypt(
            &mut Cursor::new(&encoded),
            &mut target,
            &[7; 32],
            bytes,
            b"exact-context",
            &format!("sha256:{}", "0".repeat(64)),
            &cipher
        )
        .is_err()
    );
    assert!(
        decrypt(
            &mut Cursor::new(&encoded),
            &mut target,
            &[8; 32],
            bytes,
            b"exact-context",
            &plain,
            &cipher
        )
        .is_err()
    );
    let mut legacy = vec![];
    let (legacy_plain, legacy_cipher) = super::super::crypto::encrypt(
        &mut vec![9; 19].as_slice(),
        &mut legacy,
        &[7; 32],
        bytes,
        b"exact-context",
    )
    .unwrap();
    assert!(
        decrypt(
            &mut Cursor::new(&legacy),
            &mut target,
            &[7; 32],
            bytes,
            b"exact-context",
            &legacy_plain,
            &legacy_cipher
        )
        .is_err()
    );
    assert!(
        super::super::crypto::decrypt(
            &mut Cursor::new(&encoded),
            &mut vec![],
            &[7; 32],
            bytes,
            b"exact-context",
            &plain,
            &cipher
        )
        .is_err()
    );
    let mut legacy_out = vec![];
    super::super::crypto::decrypt(
        &mut Cursor::new(&legacy),
        &mut legacy_out,
        &[7; 32],
        bytes,
        b"exact-context",
        &legacy_plain,
        &legacy_cipher,
    )
    .unwrap();
    assert_eq!(legacy_out, vec![9; 19]);
}

mod canonical;
