# Core switch migration: ICX6650 to UniFi Aggregation Pro

How to move the network core from the Brocade ICX6650 to a UniFi
USW-Pro-Aggregation (Agg Pro) with the cluster up the whole time. Routing stays
on the UDM SE; the Agg Pro is a layer 2 core.

The approach is to run both switches side by side, joined by one temporary
10G link, and move devices across one at a time. The ICX's config is left alone
until the end, so every step can be undone by moving the cables back.

The work is in two parts:

- **Part 1 (Phases 0–5):** move everything off the ICX.
- **Part 2:** bring spanning tree back across the whole network once the ICX is
  gone.

## Timeline

The goal is to get the ICX out as quickly as possible, so Part 1 is done in one
sitting on the day the Agg Pro arrives:

| When                       | What                                                                                          | Impact                                             |
| -------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Before arrival             | Phase 0: prep, profiles, labels                                                               | none                                               |
| Arrival day, first hour    | Phase 1: rack, adopt, firmware, interconnect, pre-configure every port and the STP priorities | none                                               |
| Same session, about 1 hour | Phases 2–4: servers, then UniFi switches, then the UDM                                        | seconds per device; 10–20 s house-wide for the UDM |
| Same session               | Phase 5: unplug and power off the ICX                                                         | none                                               |
| Next day                   | Part 2: verify spanning tree, edge ports and Loop Protection                                  | none, unless the optional loop test is run         |
| About a week later         | Pull the ICX from the rack once nothing has needed a rollback                                 | none                                               |

Phases 2–4 can't be rushed past the per-node health checks, because Ceph has
only three OSDs. Allow about 5 minutes per node; everything else moves in
seconds.

## Why

- The ICX runs FastIron 08.0.30u, which has a single-STP bug: putting VLAN 12
  into the spanning-tree instance stops traffic on every `no spanning-tree`
  LAG (root-caused 2026-10-30). STP therefore stays off on the ICX, so it
  doesn't pass BPDUs, and UniFi RSTP can't see a loop that crosses it.
- The ICX can't be seen or managed from the UniFi controller or the unifi MCP.
  Every change goes through an interactive CLI over SSH.
- Once the Agg Pro is the core, the whole tree is UniFi, RSTP covers all of it,
  and the core shows up in the controller.

## Current core (inventory taken 2026-11-01)

| ICX ports | Device                               | LAG                            | VLANs                                         | Cable / optic on the ICX                      |
| --------- | ------------------------------------ | ------------------------------ | --------------------------------------------- | --------------------------------------------- |
| 1/1/55–56 | UDM SE (SFP+1/SFP+2, `eth9`/`eth10`) | `udm` id 5                     | untagged 1; tagged 10, 12, 13, 21, 200, 3000  | third-party; 1m DAC                           |
| 1/1/51–52 | Switch Pro Max 24 PoE (ports 25–26)  | `ProMax24PoE` id 2047          | same trunk                                    | 3m DAC; third-party                           |
| 1/1/49–50 | Switch Pro Max 24 (ports 25–26)      | `ProMax24` id 2040             | same trunk                                    | 3m DAC; 1m DAC                                |
| 1/1/53–54 | Switch Pro Max 16 PoE (ports 17–18)  | `ProMax16PoE` id 2041          | same trunk                                    | 10GE SR + 10GE LRM optics (a mismatched pair) |
| 1/1/1–2   | home-node-01                         | `k8s-node-01` id 1, LACP short | untagged 12 (`dual-mode 12`); tagged 21, 3000 | third-party                                   |
| 1/1/3–4   | home-node-02                         | `k8s-node-02` id 2, LACP short | as above                                      | third-party                                   |
| 1/1/5–6   | home-node-03                         | `k8s-node-03` id 3, LACP short | as above                                      | third-party                                   |
| 1/1/11–12 | NAS (10.12.0.6)                      | `nas` id 4, LACP short         | untagged 12 only                              | third-party                                   |

"Third-party" is what `show media` reports as `UNSUPPORTED`: optics or DACs that
aren't Brocade-coded. They work on the ICX.

Other facts that matter for the move:

- The nodes run Talos with `bond0` in 802.3ad (`lacpRate: fast`,
  `xmitHashPolicy: layer3+4`) over Intel X710 10G ports. Their address comes
  from DHCP on untagged VLAN 12, with `bond0.21` and `bond0.3000` on top
  ([`talos/cluster.yaml.j2`](../talos/cluster.yaml.j2)).
- Rook Ceph has one OSD on each node, so taking a node away leaves Ceph degraded
  but available. Take away two and I/O stops. That is why nodes move one at a
  time.
- VLAN 99 (OOB-Mgmt, 10.99.0.0/24) stays on the UDM (ports 3 and 4) and never
  reaches the core. Keep it off the Agg Pro.
- The UDM, ICX and all UniFi switches are 10G SFP+ only, and so are the nodes'
  X710s. Nothing currently uses the Agg Pro's SFP28 (25G) ports.
- The unifi MCP runs in the cluster. Anything that cuts the UDM↔core path cuts
  it off too; reconnect with `/mcp` afterwards. The UniFi UI at
  https://10.99.0.1 stays reachable from the OOB workstation (UDM port 4).
- The ICX management port is reachable out of band at 10.99.0.6 (mgmt1, cabled
  to UDM port 3), independent of its data ports.

## Target layout on the Agg Pro

Servers are on the left and uplinks on the right, with the UDM furthest right,
because the UniFi switches' SFP+ ports are on their right-hand side. UniFi
aggregates need contiguous member ports. Each pair starts on an odd port, so its
two cables sit stacked top and bottom.

| Agg Pro ports | Device                                        | Port profile |
| ------------- | --------------------------------------------- | ------------ |
| 1–2           | home-node-01                                  | K8s Node     |
| 3–4           | home-node-02                                  | K8s Node     |
| 5–6           | home-node-03                                  | K8s Node     |
| 7–8           | NAS                                           | NAS          |
| 9–16          | spare (server side)                           |              |
| 17            | ICX interconnect (**temporary**, single link) | Core Trunk   |
| 18–20         | spare                                         |              |
| 21–22         | Switch Pro Max 16 PoE                         | Core Trunk   |
| 23–24         | Switch Pro Max 24                             | Core Trunk   |
| 25–26         | Switch Pro Max 24 PoE                         | Core Trunk   |
| 27–28         | UDM SE                                        | Core Trunk   |
| 29–32 (SFP28) | spare                                         |              |

Port profiles (create these in Phase 0):

| Profile    | Native VLAN             | Tagged VLANs                                                                                                              | STP port mode |
| ---------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------- |
| Core Trunk | Default (1)             | ServerVLAN 10, Kubernetes Cluster 12, IPCameraVLAN 13, IoT-VLAN 21, ClientVLAN 200, VPN Network 3000. **Not** OOB-Mgmt 99 | not edge      |
| K8s Node   | Kubernetes Cluster (12) | IoT-VLAN 21, VPN Network 3000                                                                                             | **Edge**      |
| NAS        | Kubernetes Cluster (12) | none                                                                                                                      | **Edge**      |

The VLANs match what the ICX carries on each port group today. PoE off and
802.1X force-authorized on all three.

Server ports have to be Edge from the start, not just in Part 2. The Agg Pro
runs RSTP as soon as it is adopted, and a non-edge port facing a device that
sends no BPDUs (Talos bonds, the NAS) waits through listening and learning,
about 30 s, before it forwards. Without Edge, every node move in Phase 2 would
cost 30 s instead of a few. BPDU guard stays off: if a stray frame shut down a
node port, that would be an outage of its own.

## The one rule

**Always move both cables of a LAG together.** If one cable of a LAG is on the
ICX and the other on the Agg Pro, the device sees two different LACP partners.
The ICX passes no BPDUs, so the loop that can follow is invisible to RSTP.
Unplug both, then plug both into their new pair.

## Phase 0: before the switch arrives (no impact)

- [ ] Create the three port profiles in UniFi (see the table above). The unifi
      MCP can't do this: its policy disables creating switch objects.
- [ ] Set all three Pro Max switches to STP priority 8192. While the ICX is in
      place, each is root of its own segment either way.
- [ ] Label all 16 cables at both ends with their ICX port and Agg Pro port.
- [ ] Choose a rack position right beside the ICX. Two of the cables are 1m DACs,
      and every cable should reach without changes.
- [ ] Get one spare DAC for the interconnect, plus one to test with.
      Optional: a matching pair of 10G SR optics to replace the Pro Max 16 PoE's
      SR + LRM mix.
- [ ] Back up the UniFi configuration (Settings → System → Backups → Download),
      and again on arrival day before Phase 1. Auto-backup is off, and as of
      2026-11-01 the newest backup on the console was from January 2025
      (Network 9.0.108).
- [ ] Save the current ICX config as the rollback reference. It is saved
      already; `show running-config` should match.

## Phase 1: install and adopt (no impact)

1. Rack and power the Agg Pro. Cable **Agg Pro port 17 → ICX 1/1/7** with one
   DAC. The ICX's spare ports are untagged VLAN 1, so the Agg Pro gets an
   address on Default and finds the controller.
2. Adopt it in UniFi, let it upgrade, and name it. Note that the device firmware
   channel is Early Access (set for the AP 8.8.14 update), so it will pull EA
   switch firmware too. Reserve its management IP.
3. Check that a third-party DAC or optic from the inventory links up in a spare
   port. UniFi doesn't block other vendors' optics, but confirm it before the
   night of the move.
4. Turn the link into a trunk. On the ICX, over OOB
   (`ssh -o HostName=10.99.0.6 -o HostKeyAlias=10.0.0.6 icx`), preview first,
   matching the UniFi uplinks (1/1/49–56 are `dual-mode` with
   `no spanning-tree`):

    ```text
    interface ethernet 1/1/7
     dual-mode
     no spanning-tree
    vlan 10
     tagged ethernet 1/1/7
    vlan 12
     tagged ethernet 1/1/7
    vlan 13
     tagged ethernet 1/1/7
    vlan 21
     tagged ethernet 1/1/7
    vlan 200
     tagged ethernet 1/1/7
    vlan 3000
     tagged ethernet 1/1/7
    ```

    VLAN 1 stays untagged, so the Agg Pro never loses the controller. Arm
    `reload after 00:00:10` first and `reload cancel` once it checks out. Only
    `write memory` after the checks pass.

5. In UniFi, set Agg Pro port 17 to **Core Trunk**.
6. Set up ports 1–8 and 21–28 now, while they are empty: build each aggregate
   from the table above and give it its profile.
7. Set the spanning-tree priorities **now**, before any UniFi switch connects
   to the Agg Pro. The Pro Max switches already run RSTP, and the Pro Max 24 PoE
   has priority 4096. If it is still 4096 when it joins the Agg Pro in Phase 3,
   it wins the root election, and the root then moves again when the
   priorities are fixed. Each root change flushes MAC tables. So: Agg Pro
   **4096**, and **all three Pro Max switches 8192** (set in Phase 0 if
   possible, which leaves only the Agg Pro for today). Leave the Flex and Flex
   Mini switches at their defaults (32768). While the ICX is still in the path
   it passes no BPDUs, so this changes nothing yet.

    The Pro Max switches are deliberately equal. In a star with no links between
    them, a non-root switch's priority only matters for choosing a new root, and
    if the Agg Pro dies each Pro Max is cut off on its own anyway, so there's no
    backup root to rank. The only rules are that the Agg Pro is lowest, and that
    each Pro Max sits below its downstream Flex switches so it stays root of its
    own island if it ever gets isolated.

**Check before moving on:** the Agg Pro is online, port 17 is up at 10G, and the
ICX's MAC table shows the Agg Pro on 1/1/7.

## Phase 2: servers, one at a time (one node out for seconds; quorum holds)

All Ceph commands run in the toolbox:
`kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph <cmd>`.

Once, before the first node:

- [ ] `ceph status` is `HEALTH_OK`.
- [ ] `ceph osd set noout`, so Ceph doesn't start rebalancing while an OSD is
      briefly gone.

For **each node** (in order: home-node-03, home-node-02, home-node-01):

1. Before starting: `kubectl get nodes` shows all Ready; etcd has 3 healthy
   members (`talosctl -n <node> etcd status`); Ceph's only warning is `noout`.
2. Optional: `kubectl cordon` and `kubectl drain` the node, to move workloads off
   ahead of time.
3. Move **both** of its cables to its Agg Pro pair. Aim for about 15 seconds.
4. Wait until both bond links are up, `bond0` keeps its 10.12.0.1x address, the
   node is Ready, etcd has 3 healthy members, and the OSD is back up
   (`ceph osd tree`) with every PG active+clean. Uncordon if you drained.
5. Only then start the next node.

Then the **NAS** (ICX 1/1/11–12 → Agg Pro 7–8), at a quiet time.

After the last one: `ceph osd unset noout`, and confirm `HEALTH_OK`.

During this phase, traffic between moved and unmoved nodes (Ceph replication
included) crosses the single 10G interconnect. That is enough, because with
`noout` each node only has to catch up on writes from the seconds it was away.

## Phase 3: UniFi switches, one at a time (seconds per switch)

In order: **Pro Max 24** (ICX 1/1/49–50 → Agg Pro 23–24), then **Pro Max 16 PoE**
(1/1/53–54 → 21–22), then **Pro Max 24 PoE** (1/1/51–52 → 25–26) last, because it
carries the APs and most of the house.

After each one: the switch is back online in UniFi at a 20 Gbps uplink, and its
clients have come back.

## Phase 4: UDM last (whole house blips for about 10–20 seconds)

Move **UDM SFP+1/SFP+2** from ICX 1/1/55–56 to **Agg Pro 27–28**. Nothing changes
on the UDM side; its aggregate stays as it is.

The Agg Pro is now the core. The ICX hangs off port 17 with nothing else on it.
The unifi MCP drops while this happens; reconnect with `/mcp`.

Check: internet works from a client on each VLAN; Cilium BGP sessions to
10.12.0.1 are Established and LoadBalancer IPs answer; Home Assistant, Zigbee,
Z-Wave and Matter are healthy.

## Phase 5: clean up

- [ ] Unplug the interconnect (Agg Pro 17 ↔ ICX 1/1/7) and power the ICX off.
      Leave it racked for about a week as the rollback.
- [ ] Remove the ICX from snmp-exporter
      ([`helmrelease.yaml`](../kubernetes/apps/o11y/snmp-exporter/app/helmrelease.yaml),
      [`snmp.yaml`](../kubernetes/apps/o11y/snmp-exporter/app/resources/snmp.yaml)),
      and remove any ICX dashboards and alerts.
- [ ] Before the ICX leaves the house or goes into storage: close the open
      privileged-access gap (`aaa authentication enable default local`) or
      factory-reset it.

## Part 2: spanning tree across the whole network (draft)

With the ICX gone, every switch in the path is UniFi, so RSTP can see the whole
tree for the first time. Most of the setup was already done in Phase 1 step 7;
this part checks it and closes the remaining gaps. Do it the day after Part 1,
once nothing has needed a rollback.

### Where things stand

- Site-wide switch STP is RSTP. It was switched from Disabled on 2026-10-30;
  check under Settings → Networks → Global Switch Settings.
- The Pro Max switches have run RSTP since then, but each one has been its own
  root, because the ICX swallowed every BPDU.
- The controller API reports `stp_role: disabled` on every port no matter what,
  so don't trust it. The only reliable view is the switch's own CLI: `ssh` to
  the switch, run `cli`, then `show spanning-tree`.

### Steps

1. **One root.** On every UniFi switch, `show spanning-tree` should name the
   Agg Pro (priority 4096) as root, with each Pro Max at 8192. Its ports should all be Designated, and each
   Pro Max should have its Agg Pro uplink as the Root port.
2. **LAGs act as one link.** Each Pro Max uplink pair should appear as a single
   aggregate port in STP, not as two member ports, one of which is blocked. If
   a member shows as blocked, the aggregate didn't form. Fix that before
   anything else.
3. **Server ports are edge.** The K8s Node and NAS profiles set Edge, so
   `show spanning-tree` should report Agg Pro ports 1–8 as edge and forwarding.
   The switch uplinks (17, 21–28) must not be edge.
4. **The UDM is not root.** The UDM keeps its default priority (32768) and
   should never win. Confirm it doesn't appear as root anywhere.
5. **Loop Protection.** Turn on UniFi Loop Protection for access ports on the
   Pro Max and Flex switches. It covers what RSTP can't: Flex Mini switches,
   which may not take part in STP (check), and unmanaged switches or hubs
   people plug in.
6. **Optional loop test,** in a quiet window: patch two free access ports on
   one Pro Max together. RSTP should block one end within seconds, and
   `show spanning-tree` should show it Alternate/Blocking. Unplug the patch
   cable to end the test. Do not test across switches or anywhere near the
   Agg Pro.
7. **Write it down.** Record the final priorities and the edge-port decision in
   this runbook.

### Rollback

If RSTP misbehaves (a port that should forward is blocked, or root keeps
changing), set the site-wide switch STP back to Disabled. That puts every
switch back in the state it was in before Part 2. The Phase 1 priorities only
matter while STP is on, so they can stay.

## Rollback

Until Phase 5, the ICX's config hasn't changed (apart from 1/1/7), so any device
goes back by moving its cables to its old ICX ports, again both cables of a LAG
together. If the Agg Pro itself fails mid-migration, move whatever has already
crossed back to the ICX. Everything the ICX had before is still configured there.

## Things to confirm on the hardware

- The Agg Pro's LAG limits. No official numbers have been found; a sibling
  model (USW-Pro-48) reportedly allows 16 LAGs with contiguous member ports.
  This plan needs 8.
- Whether the third-party optics and DACs link up on the Agg Pro (Phase 1, step 3).
