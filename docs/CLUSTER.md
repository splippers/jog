# JOG — multiple servers on a client-heavy network

## What “connect multiple JOG servers” cannot mean (safely)

On **one broadcast domain (same VLAN / same dumb switch)**, you must **not** run **multiple independent DHCP servers** handing the same address pool. Clients will see conflicting offers; imaging becomes flaky.

## Valid scaling patterns

### 1) **Split by physical imaging segments (recommended)**

Deploy **one JOG per imaging switch / table / cable bundle**, each with:

- its own **RFC1918 subnet** (e.g. `10.99.1.0/24`, `10.99.2.0/24`, …)
- its own **USB uplink** to that segment only
- its own **FOG** instance *or* a shared design (below)

Clients are partitioned **by wiring**, not by magic on one LAN.

### 2) **One FOG “brain”, many storage nodes (official FOG model)**

Run **one primary FOG** (MySQL + web + scheduler) and add **FOG storage nodes** so unicast imaging can fan out across disks and NICs. This is the supported way to **saturate disk I/O and NICs** without fighting DHCP.

- Configure in the FOG UI: storage groups, replication, node bandwidth.
- JOG laptops can act as **storage-only** hosts if you install the FOG storage node packages/roles there (advanced; usually a server-class node).

See upstream: [FOG Project documentation](https://docs.fogproject.org/) and storage group guides on [fogproject.org](https://fogproject.org/).

### 3) **Edge JOG + image sync (JOG helper)**

For “satellite” laptops that only need a **local copy of `/images`** and maybe a **local HTTP/TFTP mirror**, use:

- `cluster/jog-node-role.env.example` for `edge` vs `standalone`
- `scripts/jog-sync-images-from-primary.sh` (rsync from the primary’s `/images` or exported volume)

Edges are **not** a second full FOG unless you intentionally run a second stack (separate DB). Rsync keeps **payload** aligned; the **database** is still authoritative on the primary unless you build HA MySQL (out of scope here).

### 4) **Higher bandwidth before more heads**

Often the cheapest win is **10GbE / LACP / better switch fabric** on one JOG before duplicating FOG.

## Cluster env file

Copy `cluster/jog-node-role.env.example` to `/etc/jog/cluster.env` (the wizard can populate `JOG_CLUSTER_MODE` and `JOG_PRIMARY_SSH`).

## Operational checklist (multi-JOG)

- [ ] Each JOG’s **USB-only DHCP** range is **non-overlapping** *or* only one DHCP server per L2 segment  
- [ ] Each JOG **NEXT SERVER** points at the node that actually serves TFTP/HTTP for that segment  
- [ ] FOG **image IDs** and API tokens line up if sharing one FOG across subnets (routing + firewall)  
- [ ] Multicast: one session per VLAN; weak clients use JOS suicide clause so they do not throttle the room  
