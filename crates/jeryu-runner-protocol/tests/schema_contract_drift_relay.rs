#[test]
fn checked_guest_relay_mirror_is_generated_from_rust() {
    let checked: serde_json::Value =
        serde_json::from_str(include_str!("../../../schemas/jeryu.relay.v1.schema.json")).unwrap();
    let generated = serde_json::to_value(jeryu_runner_protocol::relay::schema()).unwrap();
    assert_eq!(checked, generated);
}

#[test]
fn direction_shapes_and_error_codes_match_the_pinned_independent_authority() {
    use serde_json::Value;
    use sha2::{Digest, Sha256};
    use std::collections::BTreeSet;
    let source = include_bytes!("fixtures/k3-relay-v1.schema.json");
    assert_eq!(
        hex::encode(Sha256::digest(source)),
        "21fddab76da1718e88dfa7ee3d360578763fcdfa0a160ad38cd224b3b704ae10"
    );
    let core: Value = serde_json::from_slice(source).unwrap();
    let mirror = serde_json::to_value(jeryu_runner_protocol::relay::schema()).unwrap();
    let required = |shape: &Value| -> BTreeSet<String> {
        shape["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|name| name.as_str().unwrap().into())
            .collect()
    };
    let fields = |shape: &Value| -> BTreeSet<String> {
        shape["properties"]
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect()
    };
    let mut tags = BTreeSet::new();
    for direction in ["GuestRelayFrame", "NodeRelayFrame"] {
        for variant in mirror["$defs"][direction]["oneOf"].as_array().unwrap() {
            let tag = variant["properties"]["type"]["const"].as_str().unwrap();
            let authority = core["$defs"]
                .as_object()
                .unwrap()
                .values()
                .find(|shape| shape["properties"]["type"]["const"].as_str() == Some(tag))
                .unwrap();
            assert_eq!(fields(variant), fields(authority), "{tag}");
            assert_eq!(required(variant), required(authority), "{tag}");
            assert_eq!(variant["additionalProperties"], Value::Bool(false));
            tags.insert(tag);
        }
    }
    let expected: BTreeSet<_> = core["oneOf"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|reference| {
            let name = reference["$ref"]
                .as_str()
                .unwrap()
                .strip_prefix("#/$defs/")
                .unwrap();
            core["$defs"][name]["properties"]["type"]["const"].as_str()
        })
        .filter(|tag| *tag != "gateway-open")
        .collect();
    assert_eq!(tags, expected);
    assert_eq!(
        mirror["$defs"]["RelayErrorCode"]["enum"],
        core["$defs"]["errorFrame"]["properties"]["error"]["enum"]
    );
    assert_eq!(
        mirror["$defs"]["Provider"]["enum"],
        core["$defs"]["open"]["properties"]["provider"]["enum"]
    );
    assert_eq!(
        mirror["$defs"]["RelayMethod"]["enum"],
        core["$defs"]["open"]["properties"]["method"]["enum"]
    );
}
