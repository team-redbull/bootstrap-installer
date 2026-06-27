import ipaddress
import logging
import sys
from typing import Any, Dict


def _validate_layout(
    network: ipaddress.IPv4Network | ipaddress.IPv6Network,
    roles: Dict[str, list],
    logger: logging.Logger,
) -> None:
    """Fail fast on an IP layout that AWS will reject or that collides.

    AWS reserves the first four addresses (network, router, DNS, future use) and
    the last (broadcast) of every subnet, so node IPs must avoid them, stay
    inside the subnet, and not duplicate each other.
    """
    net_addr = network.network_address
    reserved = {str(net_addr + i) for i in range(4)} | {str(network.broadcast_address)}

    errors = []
    seen: Dict[str, str] = {}
    for role, ips in roles.items():
        for ip in ips:
            if ipaddress.ip_address(ip) not in network:
                errors.append(f"{role} IP {ip} is outside subnet {network}")
            if ip in reserved:
                errors.append(
                    f"{role} IP {ip} collides with an AWS-reserved address "
                    f"(first four or broadcast of {network}) — raise the offset"
                )
            if ip in seen:
                errors.append(f"{role} IP {ip} duplicates the {seen[ip]} IP")
            else:
                seen[ip] = role

    if errors:
        logger.error("Invalid IP layout for the AWS subnet:")
        for e in errors:
            logger.error(f"  - {e}")
        sys.exit(1)


def calculate_ips(
    segment: str,
    profile: Dict[str, Any],
    logger: logging.Logger,
) -> Dict[str, Any]:
    """
    Calculate all IPs from the subnet CIDR and site profile offsets.

    Default convention (AWS reserves .0-.3 and the last address, so offsets start
    higher than on bare metal):
        .10-.12 = infra nodes       (ingress — *.apps DNS round-robin)
        .20-.22 = control plane     (API — api/api-int DNS round-robin)
        .30     = bootstrap
    No VIPs — DNS round-robin across all nodes in each role.
    """
    network = ipaddress.ip_network(segment, strict=False)
    net_addr = network.network_address

    infra_ips = [str(net_addr + o) for o in profile.get("infra_ip_offsets", [10, 11, 12])]
    cp_ips = [str(net_addr + o) for o in profile.get("control_plane_ip_offsets", [20, 21, 22])]
    bootstrap_ip = str(net_addr + profile.get("bootstrap_ip_offset", 30))
    compute_ips = [str(net_addr + o) for o in profile.get("compute_ip_offsets", [])]

    logger.info(f"Network: {network}")
    logger.info(f"Control Plane IPs: {cp_ips}  (api / api-int)")
    logger.info(f"Infra IPs:         {infra_ips}  (*.apps ingress)")
    logger.info(f"Bootstrap IP:      {bootstrap_ip}")
    if compute_ips:
        logger.info(f"Compute IPs:       {compute_ips}")

    _validate_layout(
        network,
        {
            "bootstrap": [bootstrap_ip],
            "control-plane": cp_ips,
            "infra": infra_ips,
            "compute": compute_ips,
        },
        logger,
    )

    return {
        "network": str(network),
        "machine_network_cidr": str(network),
        "prefix_length": network.prefixlen,
        "netmask": str(network.netmask),
        "infra_ips": infra_ips,
        "control_plane_ips": cp_ips,
        "bootstrap_ip": bootstrap_ip,
        "compute_ips": compute_ips,
    }
