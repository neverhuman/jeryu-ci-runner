use base64ct::{Base64, Encoding};
use jeryu_runner_protocol::{relay::*, wire::v2::*};
use serde_json::{Value, json};

fn open() -> Value {
    json!({"type":"open","request_id":"relay-1","provider":"claude",
        "method":"POST","path":"/v1/messages","headers":[]})
}
fn guest(value: Value) -> GuestRelayFrame {
    serde_json::from_value(value).unwrap()
}
#[test]
fn helper_authorization_and_guest_authority_injection_never_validate() {
    guest(open()).validate().unwrap();
    for name in [
        "session_id",
        "generation",
        "lease_id",
        "owner_id",
        "capability",
        "host",
    ] {
        let mut value = open();
        value[name] = json!("injected");
        assert!(serde_json::from_value::<GuestRelayFrame>(value).is_err());
    }
    let mut value = open();
    value["authorization"] = json!("DO_NOT_DEBUG_THIS_CREDENTIAL");
    let frame = guest(value);
    assert_eq!(
        frame.validate(),
        Err(RelayErrorCode::GuestAuthorizationRejected)
    );
    assert!(!format!("{frame:?}").contains("DO_NOT_DEBUG"));
    let mut value = open();
    value["authorization"] = Value::Null;
    assert!(serde_json::from_value::<GuestRelayFrame>(value).is_err());
}

#[test]
fn relay_paths_and_headers_follow_the_normative_rules() {
    for path in [
        "/",
        "/v1/",
        "/v1//messages",
        "/./v1",
        "/v1/../x",
        "//host/v1",
        "https://host/v1",
        "/v1?token=x",
        "/v1%2fprivate",
        "/v1#x",
        "/v1\\x",
        "/v1\n",
    ] {
        let mut value = open();
        value["path"] = json!(path);
        assert_eq!(
            guest(value).validate(),
            Err(RelayErrorCode::RelayStreamInvalid)
        );
    }
    for headers in [
        json!([{"name":"accept","value":""}]),
        json!([{"name":"accept","value":"a\r\nx: y"}]),
        json!([{"name":"accept","value":"a"},{"name":"accept","value":"b"}]),
        json!([{"name":"accept","value":"é"}]),
        json!([{"name":"content-type","value":"a".repeat(257)}]),
    ] {
        let mut value = open();
        value["headers"] = headers;
        assert!(guest(value).validate().is_err());
    }
    for forbidden in ["authorization", "cookie", "x-api-key", "host"] {
        let mut value = open();
        value["headers"] = json!([{"name":forbidden,"value":"rejected"}]);
        assert!(serde_json::from_value::<GuestRelayFrame>(value).is_err());
    }
}

#[test]
fn body_chunks_are_canonical_padded_and_bounded_before_streaming() {
    for size in [1, 32768] {
        let bytes = vec![42; size];
        assert_eq!(body_bytes(&Base64::encode_string(&bytes)).unwrap(), bytes);
    }
    for encoded in [
        "".into(),
        "TWE".into(),
        "Zh==".into(),
        "!!!!".into(),
        Base64::encode_string(&vec![42; 32769]),
        "A".repeat(262144),
    ] {
        assert_eq!(
            body_bytes(&encoded),
            Err(RelayErrorCode::RelayStreamInvalid)
        );
    }
    assert!(
        guest(json!({"type":"request-body","request_id":"relay-1","seq":0,"bytes_b64":"YQ=="}))
            .validate()
            .is_err()
    );
}

#[test]
fn response_headers_and_error_codes_are_closed_and_redacted() {
    let head = |status, headers| json!({"type":"head","request_id":"relay-1","status":status,"headers":headers});
    let node = |value| serde_json::from_value::<NodeRelayFrame>(value).unwrap();
    node(head(
        200,
        json!([{"name":"content-type","value":"text/event-stream"}]),
    ))
    .validate()
    .unwrap();
    assert!(node(head(600, json!([]))).validate().is_err());
    assert!(
        node(head(200, json!([{"name":"accept","value":"anything"}])))
            .validate()
            .is_err()
    );
    for header in ["set-cookie", "authorization"] {
        assert!(
            serde_json::from_value::<NodeRelayFrame>(head(
                200,
                json!([{"name":header,"value":"never-forward"}])
            ))
            .is_err()
        );
    }
    assert!(
        serde_json::from_value::<NodeRelayFrame>(
            json!({"type":"error","request_id":"relay-1","error":"raw upstream diagnostic"})
        )
        .is_err()
    );
    let secret = RelayHeader {
        name: RelayHeaderName::Accept,
        value: "DO_NOT_DEBUG_HEADER".into(),
    };
    assert!(!format!("{secret:?}").contains("DO_NOT_DEBUG"));
    let frame = node(
        json!({"type":"response-body","request_id":"relay-1","seq":1,"bytes_b64":Base64::encode_string(b"DO_NOT_DEBUG_BODY")}),
    );
    assert_eq!(format!("{frame:?}"), "NodeRelayFrame { content: redacted }");
}
