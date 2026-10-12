//! Privileged filesystem fixtures are a separate admitted-guest test lane.
//! This guard is not an admission grant or a real VMM/provider receipt.
pub(crate) fn require_admitted_guest() {
    assert_eq!(
        std::env::var("JERYU_ADMITTED_GUEST").as_deref(),
        Ok("1"),
        "privileged fixtures require the admitted-guest test entrypoint"
    );
    assert!(
        nix::unistd::Uid::effective().is_root(),
        "guest-root fixtures required"
    );
    let result = std::process::Command::new("systemd-detect-virt")
        .arg("--vm")
        .output()
        .expect("guest virtualization detection");
    assert!(result.status.success());
    let kind = String::from_utf8(result.stdout).expect("guest virtualization identity");
    assert!(
        ["kvm", "qemu"].contains(&kind.trim()),
        "qualified CI guest required"
    );
}
