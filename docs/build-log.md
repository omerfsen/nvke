# Build log

Every step, command, failure and fix, written as it happens. Dead ends stay in.

## 2026-10-30: first management cluster on KVM

### Goal

An Ansible collection for Galaxy, `omerfsen.nvke`, that installs an NVIDIA
Kubernetes Engine (NVKE) management cluster, built like `omerfsen.stratum`:
pinned, idempotent, KVM as the first provider. GPU nodes, the management
plane and NICo come later, on GPU hardware. Source of truth: NVKE's
documentation at docs.nvidia.com/nvke; the repository
(github.com/dsx-ai-factory/nvke) where the docs say nothing.

### What NVKE is, and the release

NVKE is NVIDIA's open-source software for running managed Kubernetes on an
AI factory's own GPU infrastructure, in preview. One installation is a
management cluster (an odd number of control-plane nodes running the NVKE
management plane) that creates workload clusters on machines from NVIDIA
Infra Controller (NICo).

```shell
gh release list -R dsx-ai-factory/nvke
# NVKE v0.22.0   Latest   2026-10-21
# (newer: cli/v0.3.0-rc.2, v0.23.0-rc.2 and -beta tags, all prereleases)
```

`v0.22.0` is the only final release, one commit (`400c24fb`) for every
component (`cli/v0.2.0`, `agent/v0.3.0`, `os-image/v0.2.0`, ...). Its pins
match the docs: Kubernetes 1.36.3, OVN-Kubernetes 2.4.2, Cluster API v1.13.6.
The releases attach SBOMs and `nvkectl` binaries but no node image and no
controller images, and the docs build all of them from source. So does this
collection.

### The install path in the docs

Seven steps (*Plan your installation*): build the node image; prepare nodes;
bootstrap; install the management plane; configure NICo; secure the API;
create clusters. The first three make the management cluster. Requirements
that shape a KVM lab:

- Nodes boot from the NVKE node image, have a TPM 2.0 (SPIRE attests them by
  TPM endorsement-key thumbprint) and get their address by DHCP.
- More than one node needs an API VIP, announced by kube-vip over **BGP**:
  AS 65100 on the nodes, AS 4294967000 on their default gateway, both fixed.
  The repository confirms there is no ARP mode
  (`agent/internal/agent/kube_vip.go`: `vip_arp=false`, `bgp_enable=true`).
- A bootstrap host with rootful nerdctl and containerd (not Docker), kind,
  helm, kubectl, clusterctl, Go, Make.
- Your own SPIRE CA: the node image cannot trust a CA it was not given.

### The host

The same KVM host as `omerfsen.stratum`: Ubuntu 22.04, 32 cores, 125 GiB RAM,
libvirt's `default` network 192.168.122.0/24 in route mode, ufw active
(default deny in), Docker installed, about 45 other VMs. `/` had 64 GiB free,
so the build directory and the VM disks go to the large data disks through a
gitignored `inventory/kvm/group_vars/all/local.yml`. Addresses .100-.103 were
free (pinged first). The VIP goes off-link, 10.250.0.10: a VIP on the node
subnet would be ARPed for and never answered.

### Node image

```shell
make -C os-image image-native ARCH=amd64 VARIANT=non-fde   # UBUNTU_RELEASE=26.04.1
```

Needs Go 1.27.3 and Packer 1.15.4 (installed checksum-verified into the build
directory, not system-wide). The package builder runs natively on the 22.04
host: an older host than the target is fine (`package-builder.sh`).

First run failed before building anything: `apt-get update` fails on this
host because of an unrelated third-party source (HashiCorp, `NO_PUBKEY`).
The roles now refresh the apt cache only when a needed package is missing;
the host's apt sources are left alone.

Second run: 15 m 45 s of Packer, about 25 minutes in all with the package
builds (kubeadm bundles for four Kubernetes versions, OVN-Kubernetes built
from source, SPIRE, DOCA OVS). Result: a 3.1 GB qcow2. Build directory: 15 GB.
`make -C os-image boot-smoke REQUIRE_ACCELERATION=1`, the docs' check after
the build: "image contract and root-filesystem growth are satisfied". It
infers the architecture from the file name (`*-amd64.qcow2`), so it runs on
Packer's output, before the copy renames it.

### Bootstrap host

An Ubuntu 24.04 cloud-image VM. nerdctl-full 2.3.5 installed the way NVKE's
own e2e host script does it: a standalone containerd and buildkitd with their
own units, socket and data root. `make -C cli build` gives
`nvkectl v0.2.0 (commit: 400c24fb)`; `make -C cli images` builds the two
seed-cluster images, tagged `:v0.22.0`.

Rerun was not clean at first: containerd keeps its root at 0711 and the role
set 0755. Fixed; rerun `changed=0`.

### First cluster attempt: the nodes vanished

Nodes booted, SPIRE files and packages in place, thumbprints read. The
bootstrap started, one node (`kubeadm init`) became Ready, then every node
stopped answering on its address. libvirt's DHCP log:

```text
DHCPACK(virbr0) 192.168.122.21 e2:73:99:97:e5:41 nvke-node1
```

During the bootstrap NVKE moves each node's NIC into an Open vSwitch bridge
that takes over its DHCP. OVS gives the bridge the NIC's MAC only when that
MAC is globally administered; QEMU's `52:54:00` is locally administered, so
the bridge asked for DHCP with a random MAC and got a dynamic address. The
repository handles exactly this for ifupdown nodes
(`open_vswitch_ifupdown.go`, `other-config:hwaddr`) but not for netplan,
which Ubuntu uses. Real NICs are not affected.

Fix: the VMs get predefined, globally administered MACs,
`00:16:3e:7a:00:<last octet of the IP in hex>` (`00:16:3e` is the prefix LXD
uses), and the playbook refuses a locally administered MAC for a node.

### Second attempt: the reserved address was taken

The rebuilt node got .25, not .101:

```text
not using configured address 192.168.122.101 because it is leased to 52:54:00:1f:50:23
```

dnsmasq keeps a destroyed VM's lease for an hour. `kvm_destroy` now releases
the leases of the VMs it removes, and `libvirt_vm` releases a stale lease on
its address when no defined VM has that MAC (`dhcp_release`).

### Third attempt: the VIP was announced but not routed

The nodes kept their addresses through the OVS move. BGP came up with the
first node and FRR had the VIP, but not the kernel:

```text
*> 10.250.0.10/32   192.168.122.103    0 65100 i     # show bgp ipv4 unicast
                                                     # ip route show 10.250.0.10: nothing
```

`bgpd` ran with `-l 192.168.122.1` to listen on the gateway only, and in FRR 8
a listen address also turns off route installation (the same as `-n`). The
other nodes could not join through the VIP. Fix: no `-l`; the sessions are
still restricted (explicit passive neighbors, ufw admits TCP 179 only from
the nodes). The route appeared at once:

```text
10.250.0.10 nhid 18 via 192.168.122.103 dev virbr0 proto bgp metric 20
```

### Review

A second, independent review of the roles against the v0.22.0 sources found:
`nvke-agent` restarted by a handler before the bootstrap fails (it waits for
SPIRE; now restarted without waiting), ICMP redirects from the gateway would
pin VMs to one node for the VIP (now off), the destroy playbook left swtpm
state behind (now removed) and deleted the only off-node etcd key (now set
aside), and `libvirt_vm` relied on packages another role installed (now its
own).

### Following the docs exactly

After the first attempts the collection was aligned with the docs page by
page:

- nodes are provisioned with the *Prepare nodes* user data at first boot, so
  the bootstrap host and the SPIRE CA come first and the nodes after;
- every Verify check of *Prepare nodes* and *Bootstrap the management cluster*
  runs;
- the site spec gets the docs' `--set` keys only;
- role defaults are the docs' defaults; the KVM inventory moves the pod
  network off 192.168.0.0/16 because it contains the node network, which the
  docs forbid;
- nodes are named `cp-01`... like the docs (`nvke-cp-01`... on KVM).

### Fourth attempt: from scratch, docs order

`kvm.yml` from nothing (the node image already built):

```text
nvke-bootstrap : ok=89  changed=30  failed=0
nvke-cp-01     : ok=18  changed=0   failed=0     # the first-boot user data had done it all
nvke-cp-02     : ok=18  changed=0   failed=0
nvke-cp-03     : ok=18  changed=0   failed=0
real 18m50s
```

```text
$ kubectl get nodes -o wide
NAME                    STATUS   ROLES           VERSION   INTERNAL-IP       OS-IMAGE             KERNEL-VERSION
nvke-mgmt-cp-8511cbf9   Ready    control-plane   v1.36.3   192.168.122.103   Ubuntu 26.04.1 LTS   7.0.0-1018-nvidia
nvke-mgmt-cp-9b531177   Ready    control-plane   v1.36.3   192.168.122.101   Ubuntu 26.04.1 LTS   7.0.0-1018-nvidia
nvke-mgmt-cp-e3a20194   Ready    control-plane   v1.36.3   192.168.122.102   Ubuntu 26.04.1 LTS   7.0.0-1018-nvidia

$ ip route show 10.250.0.10
10.250.0.10 nhid 74 proto bgp metric 20
        nexthop via 192.168.122.103 dev virbr0 weight 1
        nexthop via 192.168.122.101 dev virbr0 weight 1
        nexthop via 192.168.122.102 dev virbr0 weight 1
```

NVKE names the Kubernetes nodes itself (`<cluster>-cp-<hash>`), not after
the hosts. All 24 pods Running; the kubeconfig on the controller points at
`https://10.250.0.10:6443`.

- Rerun: `changed=0` on every host (the first rerun set the controller's copy
  of the CA key to 0600: `fetch` does not keep modes; fixed).
- Failover: `nvke-cp-03` (the node that ran `kubeadm init`) shut down; its
  route left the ECMP set after about 30 s and the API answered through the
  VIP at every check. Started again, it came back on its reserved address,
  its route returned after 36 s, and node and pods were Ready 30 s later.

### Galaxy readiness

- `ansible-lint --profile production`: passed; `--syntax-check` on every
  playbook.
- `galaxy-importer` 0.4.44 on the built tarball: first "No role readme
  found" (each role got a README), then `syntax-check[unknown-module]` for
  `ansible.posix.synchronize`, `ansible.posix.sysctl` and
  `community.general.ufw`: the importer lints without installing
  dependencies. All three replaced with `ansible.builtin` tasks (copy through
  the controller, a `sysctl.d` file, idempotent `ufw`/`firewall-cmd`
  commands), and the collection has no dependencies left. Importer: completed
  with no warnings.
- Full `kvm.yml` rerun after those changes: `changed=0` on all five hosts.

## 2026-10-30: GPU nodes, on a KVM host with one GPU

### The host

Ubuntu 24.04.5, kernel 6.8.0-147, AMD Ryzen 9 9900X (12 cores, 24
threads, AMD-V), 92 GiB RAM, 270 GiB free on `/`. One GPU, a GeForce RTX 4080
SUPER (`10de:2702`, 16 GiB) at `01:00.0` with its HDMI audio (`10de:22bb`) at
`01:00.1`, both alone in IOMMU group 13 (the IOMMU is on by default on this
AMD board, no kernel parameter). The GPU is also the firmware's boot display;
an AMD iGPU (`12:00.0`) drives the console. Secure Boot is on, and the host
runs Canonical's signed NVIDIA 615 modules. libvirt's `default` network here
is 192.168.90.0/24, so `local.yml` moves the VMs there.

### Does a GPU node need passthrough?

Yes. The docs (*Build and verify your own node image*): the node image "is
not a ready Kubernetes node: `nvke-agent` installs Kubernetes later, and the
NVIDIA GPU Operator installs GPU drivers". A GPU node boots the NVKE node
image like every other node, so the host's own driver is of no use, and on a
KVM host the GPU node is a VM that owns the GPU through VFIO.

In NVKE's design GPU nodes are workload-cluster nodes that NICo (NVIDIA
Infra Controller, the bare-metal provisioner behind CAPNICo) provisions. There
is no NICo here, and the docs' mock-NICo starts workload nodes as Docker
containers, which cannot hold a passed-through GPU. So the GPU goes to a
management-cluster node VM.

### Binding the GPU to vfio-pci

`omerfsen.nvke.gpu_passthrough` follows the passthrough that already ran on
this host for another project: permanent mode only (a live detach of this
card from the host driver once froze the host), the host NVIDIA modules
refused with `install <module> /bin/false` (a plain blacklist leaves the
NVIDIA udev rule reloading them in a loop), vfio-pci ids plus softdeps, the
initrd rebuilt, and a gate that stops the play until the host has been
rebooted onto vfio-pci. The first run stops there, as designed:

```text
TASK [omerfsen.nvke.gpu_passthrough : Every device is on vfio-pci]
failed: [localhost] (item=0000:01:00.0)   # still on nvidia: reboot first
```

The lint venv failed first: `python3` on this host's PATH is Python 3.15,
which ansible-core 2.16 does not support (`ImportError: cannot import name
'_MISSING_TYPE'`). `make dev PYTHON=<python3.12>` picks the interpreter.
