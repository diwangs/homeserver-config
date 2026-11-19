#!/bin/bash
# Entrypoint of the multipan container (roles/tenant/iot). Runs inside the upstream
# Silicon Labs Multiprotocol add-on image, using that image's own binaries, but replaces
# its s6/bashio tree: every bashio call there (options, ports, the primary interface)
# goes to the Home Assistant Supervisor API, which does not exist outside HAOS.
#
# Mirrors the add-on's run/finish scripts as of 2.4.6 (etc/s6-overlay in the image):
#   mdnsd -> cpcd -> (cpcd socket up) -> zigbeed + otbr-agent, plus the OTBR forward
#   firewall. Deliberately NOT started: universal-silabs-flasher (autoflash, would
#   rewrite the radio's firmware) and otbr-web.
#
# Like the add-on (whose finish scripts halt the container), the first daemon to exit
# takes the whole stack down; systemd (Restart=always on docker-multipan) brings it back.
#
# State, bind-mounted by configuration.nix:
#   /data/zigbeed     zigbeed's working directory: the Zigbee network (key, PAN IDs,
#                     frame counter) lives here, not on the RCP radio
#   /var/lib/thread   otbr-agent's settings (Thread dataset)
set -euo pipefail

thread_if=wpan0
backbone_if="${BACKBONE_IF:?BACKBONE_IF must be set}"
otbr_log_level="${OTBR_LOG_LEVEL:-5}" # 5 = notice, the add-on default
ingress_chain=OTBR_FORWARD_INGRESS
egress_chain=OTBR_FORWARD_EGRESS
ipsets="otbr-ingress-deny-src otbr-ingress-deny-src-swap otbr-ingress-allow-dst otbr-ingress-allow-dst-swap"

log() { echo "[multipan] $*"; }

# otbr-agent-common / otbr-agent/finish. Safe to run when nothing is set up.
firewall_down() {
    while ip6tables -C FORWARD -o "$thread_if" -j "$ingress_chain" 2>/dev/null; do
        ip6tables -D FORWARD -o "$thread_if" -j "$ingress_chain"
    done
    if ip6tables -L "$ingress_chain" >/dev/null 2>&1; then
        ip6tables -w -F "$ingress_chain"
        ip6tables -w -X "$ingress_chain"
    fi
    while ip6tables -C FORWARD -i "$thread_if" -j "$egress_chain" 2>/dev/null; do
        ip6tables -D FORWARD -i "$thread_if" -j "$egress_chain"
    done
    if ip6tables -L "$egress_chain" >/dev/null 2>&1; then
        ip6tables -w -F "$egress_chain"
        ip6tables -w -X "$egress_chain"
    fi
    # The kernel may hold a set briefly after its rules go; retry a few times.
    for set in $ipsets; do
        for _ in 1 2 3 4 5; do
            ipset list -n "$set" >/dev/null 2>&1 || break
            ipset destroy "$set" 2>/dev/null || sleep 1
        done
    done
}

# otbr-agent/run with otbr_firewall: true (the add-on default). otbr-agent fills the
# ipsets itself at runtime.
firewall_up() {
    for set in $ipsets; do
        ipset create -exist "$set" hash:net family inet6
    done

    ip6tables -N "$ingress_chain"
    ip6tables -I FORWARD 1 -o "$thread_if" -j "$ingress_chain"
    ip6tables -A "$ingress_chain" -m pkttype --pkt-type unicast -i "$thread_if" -j DROP
    ip6tables -A "$ingress_chain" -m set --match-set otbr-ingress-deny-src src -j DROP
    ip6tables -A "$ingress_chain" -m set --match-set otbr-ingress-allow-dst dst -j ACCEPT
    ip6tables -A "$ingress_chain" -m pkttype --pkt-type unicast -j DROP
    ip6tables -A "$ingress_chain" -j ACCEPT

    ip6tables -N "$egress_chain"
    ip6tables -I FORWARD 2 -i "$thread_if" -j "$egress_chain"
    ip6tables -A "$egress_chain" -j ACCEPT
}

pids=()
cleanup() {
    trap - TERM INT EXIT
    log "stopping"
    if [ "${#pids[@]}" -gt 0 ]; then
        kill "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
    firewall_down
    rm -rf /dev/shm/cpcd
}
trap cleanup TERM INT EXIT

# The image ships a stale pid file from its build.
rm -f /run/mdnsd.pid
mkdir -p /data/zigbeed /var/lib/thread
radio=$(sed -n 's/^uart_device_file: //p' /usr/local/etc/cpcd.conf)
test -c "$radio" || { log "$radio is missing (is the radio passed into the CT?)"; exit 1; }

# Leftovers from an unclean stop would make `ip6tables -N` fail.
firewall_down
firewall_up

log "starting mdnsd"
/usr/sbin/mdnsd -debug &
pids+=("$!")

# Reads /usr/local/etc/cpcd.conf (rendered by configuration.nix, bind-mounted read-only).
log "starting cpcd"
/usr/bin/stdbuf -o0 /usr/local/bin/cpcd &
pids+=("$!")

# cpcd/data/check: the control socket appears once the RCP has answered (300 s, as s6-notifyoncheck).
for _ in $(seq 1 300); do
    [ -S /dev/shm/cpcd/cpcd_0/ctrl.cpcd.sock ] && break
    kill -0 "${pids[1]}" 2>/dev/null || { log "cpcd exited before it was ready"; exit 1; }
    sleep 1
done
[ -S /dev/shm/cpcd/cpcd_0/ctrl.cpcd.sock ] || { log "cpcd did not become ready"; exit 1; }

# Listens on all addresses as in the add-on; nixos-fw keeps 9999 closed, Z2M uses loopback.
log "starting zigbeed"
(cd /data/zigbeed && exec /usr/local/bin/zigbeed \
    --radio-url "spinel+cpc://cpcd_0?iid=1&iid-list=0" \
    --ezsp-listen :: \
    --ezsp-listen-port 9999) &
pids+=("$!")

log "starting otbr-agent (backbone ${backbone_if})"
/usr/sbin/otbr-agent -I "$thread_if" -B "$backbone_if" \
    --rest-listen-address :: \
    -d"$otbr_log_level" -v \
    "spinel+cpc://cpcd_0?iid=2&iid-list=0" &
pids+=("$!")

set +e
wait -n "${pids[@]}"
rc=$?
log "a daemon exited (status ${rc}); taking the stack down"
exit "$rc"
