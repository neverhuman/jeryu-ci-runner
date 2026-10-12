//! Dispatch only the processes selected by the admitted session profile.
use super::*;

pub(super) fn launch(
    profile_id: &str,
    rebase_required: bool,
    mut send: impl FnMut(&GuestRequest) -> RunnerResult<()>,
) -> RunnerResult<()> {
    // Resolve before dispatch so an invalid profile never starts a process.
    let profile =
        GuestProfile::registered(profile_id).map_err(|_| failed("unknown_agent_profile"))?;
    send(&GuestRequest::Start {
        channel: "shell".into(),
        profile: GuestProfile::Shell,
    })?;
    if !rebase_required && profile != GuestProfile::Shell {
        send(&GuestRequest::Start {
            channel: "agent".into(),
            profile,
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_only_and_conflicted_sessions_launch_one_shell() {
        for profile in [
            GuestProfile::Shell,
            GuestProfile::Fixture,
            GuestProfile::MockClaude,
            GuestProfile::MockCodex,
            GuestProfile::MockGrok,
        ] {
            for conflict in [false, true] {
                let mut launches = Vec::new();
                launch(profile.id(), conflict, |request| {
                    request.validate().unwrap();
                    if let GuestRequest::Start { channel, profile } = request {
                        launches.push((channel.clone(), *profile));
                    } else {
                        panic!("startup dispatched a non-start operation");
                    }
                    Ok(())
                })
                .unwrap();
                let expected = if conflict || profile == GuestProfile::Shell {
                    vec![("shell".into(), GuestProfile::Shell)]
                } else {
                    vec![
                        ("shell".into(), GuestProfile::Shell),
                        ("agent".into(), profile),
                    ]
                };
                assert_eq!(launches, expected);
            }
        }
    }

    #[test]
    fn invalid_profile_and_failed_shell_dispatch_cannot_launch_an_agent() {
        let mut sent = 0;
        assert!(
            launch("unknown", false, |_| {
                sent += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(sent, 0);
        assert!(
            launch("mock-codex", false, |_| {
                sent += 1;
                Err(failed("microvm_not_running"))
            })
            .is_err()
        );
        assert_eq!(sent, 1);
    }
}
