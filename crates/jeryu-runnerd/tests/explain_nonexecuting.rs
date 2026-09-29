use std::path::PathBuf;
use std::process::{Command, Output};

fn explain(fixture: &str, execution_flag: &str, launcher_var: &str) -> Output {
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples/jobs")
        .join(fixture);
    Command::new(env!("CARGO_BIN_EXE_jeryu-runnerd"))
        .args(["explain", fixture.to_str().expect("fixture path is UTF-8")])
        .env(execution_flag, "1")
        .env(launcher_var, "/definitely/not/an/executable")
        .output()
        .expect("runnerd explain process starts")
}

fn assert_planned(output: Output) {
    assert!(
        output.status.success(),
        "explain failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).expect("receipt is UTF-8");
    assert!(stdout.contains("\"status\":\"planned\""), "{stdout}");
    assert!(stdout.contains("\"exit_code\":null"), "{stdout}");
}

#[test]
fn microvm_explain_ignores_execution_opt_in() {
    assert_planned(explain(
        "t4-fork-pr.job",
        "JERYU_RUN_MICROVM",
        "JERYU_MICROVM_BIN",
    ));
}

#[test]
fn oci_explain_ignores_execution_opt_in() {
    assert_planned(explain(
        "oci-compat.job",
        "JERYU_RUN_OCI",
        "JERYU_OCI_RUNTIME",
    ));
}
