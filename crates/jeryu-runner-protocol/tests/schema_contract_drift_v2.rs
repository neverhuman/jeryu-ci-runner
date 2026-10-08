#[test]
fn checked_v2_schema_is_generated_from_the_rust_types() {
    let checked: serde_json::Value =
        serde_json::from_str(include_str!("../../../schemas/jeryu.runner.v2.schema.json")).unwrap();
    let generated = serde_json::to_value(jeryu_runner_protocol::wire::v2::schema()).unwrap();
    assert_eq!(
        checked, generated,
        "run cargo run --locked -p jeryu-runner-protocol --example generate_v2_schema > schemas/jeryu.runner.v2.schema.json"
    );
    for name in [
        "SessionLease",
        "SessionContext",
        "ControlRequest",
        "ControlAck",
        "TerminalFrame",
        "RuntimeManifest",
        "SessionResources",
        "ArtifactIdentity",
    ] {
        assert_eq!(
            checked["$defs"][name]["additionalProperties"], false,
            "{name}"
        );
    }
}
