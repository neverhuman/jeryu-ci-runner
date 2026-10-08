#[test]
fn checked_guest_schema_is_generated_from_the_rust_types() {
    let checked: serde_json::Value =
        serde_json::from_str(include_str!("../../../schemas/jeryu.guest.v2.schema.json")).unwrap();
    let generated = serde_json::to_value(jeryu_runner_protocol::guest::schema()).unwrap();
    assert_eq!(checked, generated);
}
