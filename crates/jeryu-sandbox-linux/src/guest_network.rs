//! Fixed loopback bootstrap for verified guest PID 1; no external network.
use nix::{
    sys::socket::{AddressFamily, SockFlag, SockType, socket},
    unistd::Uid,
};
use std::{io, os::fd::AsRawFd};

/// Configure only `lo` as 127.0.0.1/8 before guest workspace preparation.
/// Calls outside guest PID 1 or without effective UID 0 fail before any I/O.
pub fn initialize_loopback() -> io::Result<()> {
    require_guest(std::process::id(), Uid::effective().as_raw())?;
    let fd = socket(
        AddressFamily::Inet,
        SockType::Datagram,
        SockFlag::SOCK_CLOEXEC,
        None,
    )
    .map_err(|_| io::Error::other("guest_loopback_socket_failed"))?;
    let raw = fd.as_raw_fd();
    let flags = read_flags(raw)?;
    require_loopback(flags)?;
    for (operation, octets) in [
        (libc::SIOCSIFADDR, [127, 0, 0, 1]),
        (libc::SIOCSIFNETMASK, [255, 0, 0, 0]),
    ] {
        let mut request = loopback_request();
        request.ifr_ifru.ifru_addr = ipv4_address(octets);
        ioctl(raw, operation, &mut request)?;
    }
    // Address ioctls overwrite the union: obtain flags in a fresh request.
    let flags = read_flags(raw)?;
    require_loopback(flags)?;
    let mut request = loopback_request();
    request.ifr_ifru.ifru_flags = flags | libc::IFF_UP as libc::c_short;
    ioctl(raw, libc::SIOCSIFFLAGS, &mut request)?;
    let flags = read_flags(raw)?;
    require_loopback(flags)?;
    if flags & libc::IFF_UP as libc::c_short == 0 {
        return Err(io::Error::other("guest_loopback_not_up"));
    }
    for (operation, octets) in [
        (libc::SIOCGIFADDR, [127, 0, 0, 1]),
        (libc::SIOCGIFNETMASK, [255, 0, 0, 0]),
    ] {
        let mut request = loopback_request();
        ioctl(raw, operation, &mut request)?;
        // SAFETY: a successful address ioctl initialized this sockaddr member.
        let address = unsafe { request.ifr_ifru.ifru_addr };
        if address.sa_family != libc::AF_INET as libc::sa_family_t
            || address.sa_data[..6] != ipv4_address(octets).sa_data[..6]
        {
            return Err(io::Error::other("guest_loopback_address_mismatch"));
        }
    }
    Ok(())
}

fn require_guest(pid: u32, effective_uid: u32) -> io::Result<()> {
    if pid != 1 || effective_uid != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "guest_loopback_pid1_root_required",
        ));
    }
    Ok(())
}

fn require_loopback(flags: libc::c_short) -> io::Result<()> {
    if flags & libc::IFF_LOOPBACK as libc::c_short == 0 {
        return Err(io::Error::other("guest_loopback_interface_mismatch"));
    }
    Ok(())
}

fn loopback_request() -> libc::ifreq {
    let mut request = libc::ifreq {
        ifr_name: [0; libc::IFNAMSIZ],
        ifr_ifru: libc::__c_anonymous_ifr_ifru {
            ifru_addr: libc::sockaddr {
                sa_family: 0,
                sa_data: [0; 14],
            },
        },
    };
    request.ifr_name[0] = b'l' as libc::c_char;
    request.ifr_name[1] = b'o' as libc::c_char;
    request
}

fn ipv4_address(octets: [u8; 4]) -> libc::sockaddr {
    let mut address = libc::sockaddr {
        sa_family: libc::AF_INET as libc::sa_family_t,
        sa_data: [0; 14],
    };
    // sockaddr_in begins with a zero port and then network-order IPv4 bytes.
    for (target, octet) in address.sa_data[2..6].iter_mut().zip(octets) {
        *target = octet as libc::c_char;
    }
    address
}

fn read_flags(fd: libc::c_int) -> io::Result<libc::c_short> {
    let mut request = loopback_request();
    ioctl(fd, libc::SIOCGIFFLAGS, &mut request)?;
    // SAFETY: SIOCGIFFLAGS successfully initialized the flags union member.
    Ok(unsafe { request.ifr_ifru.ifru_flags })
}

fn ioctl(fd: libc::c_int, operation: u64, request: &mut libc::ifreq) -> io::Result<()> {
    // SAFETY: only fixed Linux interface ioctls receive a live, aligned ifreq.
    // The inferred cast uses GNU's unsigned long or musl's int request ABI.
    if unsafe { libc::ioctl(fd, operation as _, request) } < 0 {
        return Err(io::Error::other("guest_loopback_ioctl_failed"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bootstrap_refuses_non_guest_before_socket_or_ioctl() {
        assert_ne!(std::process::id(), 1);
        let error = initialize_loopback().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(error.to_string(), "guest_loopback_pid1_root_required");
        assert!(require_guest(1, 1000).is_err());
        assert!(require_guest(2, 0).is_err());
    }

    #[test]
    fn fixed_loopback_request_preserves_network_octets() {
        let request = loopback_request();
        assert_eq!(
            request.ifr_name[..3],
            [b'l' as libc::c_char, b'o' as libc::c_char, 0]
        );
        assert!(request.ifr_name[3..].iter().all(|byte| *byte == 0));
        for octets in [[127, 0, 0, 1], [255, 0, 0, 0]] {
            let address = ipv4_address(octets);
            assert_eq!(address.sa_family, libc::AF_INET as libc::sa_family_t);
            assert_eq!(&address.sa_data[..2], &[0, 0]);
            assert_eq!(
                address.sa_data[2..6]
                    .iter()
                    .map(|byte| *byte as u8)
                    .collect::<Vec<_>>(),
                octets
            );
            assert!(address.sa_data[6..].iter().all(|byte| *byte == 0));
        }
    }
}
