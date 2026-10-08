//! These malformed records have valid AEAD and matching supplied digests.
//! Refusal therefore proves canonical validation, not merely corruption checks.
use super::*;

fn signed_invalid(bytes: u64, records: &[(u64, Vec<u8>)]) -> (Vec<u8>, String) {
    let mut header = [0; 24];
    header[..8].copy_from_slice(MAGIC);
    header[8..16].copy_from_slice(&bytes.to_be_bytes());
    header[16..].copy_from_slice(&[9; 8]); // Isolated deterministic fixture nonce.
    let k = key(&[7; 32]).unwrap();
    let aad = associated(&header, b"exact-context");
    let mut out = header.to_vec();
    let mut digest = plaintext_hash(bytes);
    for (seq, (offset, bytes)) in records.iter().enumerate() {
        let seq = seq as u32;
        let meta = descriptor(*offset, bytes.len() as u32, seq);
        digest.update(&meta[..12]);
        digest.update(bytes);
        let mut body = bytes.clone();
        k.seal_in_place_append_tag(
            nonce(&header, seq),
            aead::Aad::from(record_aad(&aad, &meta, 0)),
            &mut body,
        )
        .unwrap();
        out.extend_from_slice(&meta);
        out.extend_from_slice(&body);
    }
    let seq = records.len() as u32;
    let meta = descriptor(bytes, 0, seq);
    let mut end = vec![];
    k.seal_in_place_append_tag(
        nonce(&header, seq),
        aead::Aad::from(record_aad(&aad, &meta, 1)),
        &mut end,
    )
    .unwrap();
    out.extend_from_slice(&meta);
    out.extend_from_slice(&end);
    (out, super::super::digest(digest))
}

#[test]
fn authentic_invalid_shapes_fail_before_noncanonical_output_can_be_accepted() {
    for (name, logical, records) in [
        ("zero data", 19, vec![(0, vec![0; 19])]),
        ("wrong partial length", 19, vec![(0, vec![3; 18])]),
        (
            "unaligned offset",
            CHUNK + 19,
            vec![(1, vec![3; CHUNK as usize])],
        ),
        (
            "overlap",
            2 * CHUNK,
            vec![(0, vec![3; CHUNK as usize]), (0, vec![5; CHUNK as usize])],
        ),
        (
            "reordered offset",
            2 * CHUNK,
            vec![
                (CHUNK, vec![3; CHUNK as usize]),
                (0, vec![5; CHUNK as usize]),
            ],
        ),
        (
            "count above logical blocks",
            19,
            vec![(0, vec![3; 19]), (0, vec![5; 19])],
        ),
    ] {
        let (encoded, digest) = signed_invalid(logical, &records);
        assert!(
            decode(&encoded, logical, b"exact-context", &digest).is_err(),
            "{name}"
        );
    }
    let mut file = fixture(19, false);
    data(&mut file, 0, 7, 19);
    let mut out = vec![];
    assert!(
        encrypt_using(
            &mut file,
            &mut out,
            &[7; 32],
            19,
            b"exact-context",
            |_, _, _| Ok(Some(20))
        )
        .is_err()
    );
    assert!(
        encrypt_using(
            &mut file,
            &mut out,
            &[7; 32],
            19,
            b"exact-context",
            |_, _, _| Ok(Some(1))
        )
        .is_err()
    );
}
