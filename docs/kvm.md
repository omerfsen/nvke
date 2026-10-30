# NVKE on KVM/libvirt

`omerfsen.nvke.kvm` builds the NVKE node image, creates the VMs on one or more
KVM hypervisors, makes the first hypervisor the BGP peer for the API VIP, and
then runs `omerfsen.nvke.cluster` on the VMs.

```shell
git clone https://github.com/omerfsen/nvke.git && cd nvke
make dev && source .venv/bin/activate
ansible-playbook playbooks/kvm.yml
```

## What it creates

With the defaults in `inventory/kvm/group_vars/all/defaults.yml`:

| VM | Address | Image | Size | Role |
|---|---|---|---|---|
| `nvke-bootstrap` | 192.168.122.100 | Ubuntu 24.04 cloud image | 4 vCPU, 8 GiB, 40 GiB | bootstrap host |
| `nvke-cp-01` | 192.168.122.101 | NVKE node image, Ubuntu 26.04.1 | 4 vCPU, 8 GiB, 40 GiB | control plane, TPM 2.0 |
| `nvke-cp-02` | 192.168.122.102 | NVKE node image | 4 vCPU, 8 GiB, 40 GiB | control plane, TPM 2.0 |
| `nvke-cp-03` | 192.168.122.103 | NVKE node image | 4 vCPU, 8 GiB, 40 GiB | control plane, TPM 2.0 |
| API VIP | 10.250.0.10 | | | announced over BGP |

Every VM is UEFI (OVMF without Secure Boot), q35, virtio, with a
`host-passthrough` CPU. The nodes get a TPM 2.0 each (libvirt runs swtpm), which
SPIRE uses to attest them: the bootstrap only admits nodes whose TPM
endorsement-key thumbprint is in the site spec.

The disks are thin qcow2 copies of the base image. The node image itself is
built once by `omerfsen.nvke.node_image` (about 16 minutes of Packer with KVM,
plus the package builds) and kept next to the disks.

## Requirements on the hypervisor

- Ubuntu or Debian with KVM, libvirt, `virt-install`, `qemu-utils`,
  `genisoimage`, `ovmf` and `swtpm`. `libvirt_vm` installs what is missing.
- About 30 GiB of RAM free for the four VMs and 10 GiB more while the image
  builds.
- Disk: the image build peaks at about 40 GiB in `node_image_build_dir`; the
  image is 3 GiB; each VM disk grows to what it uses (about 10-20 GiB).
- Outbound access to GitHub, the Go module proxy, Ubuntu's archive and ISO
  mirrors, Docker Hub, `ghcr.io`, `registry.k8s.io` and `dl.k8s.io`.

Put the big directories on a large disk in a gitignored override, for example
`inventory/kvm/group_vars/all/local.yml`:

```yaml
node_image_build_dir: /data/nvke-build
nvke_kvm_disk_path: /data/vms
```

Files in `group_vars/all/` load in name order, so `local.yml` overrides
`defaults.yml`.

## Network

The VMs use libvirt's `default` network. The node image configures every
`e*` interface with DHCP and ignores cloud-init network configuration, so each
VM gets its address from a **DHCP reservation** that `libvirt_vm` adds to the
network for the VM's predefined MAC (`virsh net-update ... ip-dhcp-host`), so
a rebuilt VM keeps its address. Reservations of
other VMs on the network are never touched; an address another MAC already
holds is an error.

### MAC addresses

Every VM has a predefined MAC, and its DHCP reservation is for that MAC. It is
`nvke_kvm_mac_prefix` (`00:16:3e`), `nvke_kvm_mac_middle` (`7a:00`) and the
last octet of the VM's address in hex, so the address can be read off the MAC:

| VM | Address | MAC |
|---|---|---|
| `nvke-bootstrap` | 192.168.122.100 | `00:16:3e:7a:00:64` |
| `nvke-cp-01` | 192.168.122.101 | `00:16:3e:7a:00:65` |
| `nvke-cp-02` | 192.168.122.102 | `00:16:3e:7a:00:66` |
| `nvke-cp-03` | 192.168.122.103 | `00:16:3e:7a:00:67` |

A rebuilt VM gets the same MAC and the same address. Pin your own per VM:

```yaml
nvke_kvm_macs:
  nvke-cp-01: "00:16:3e:10:00:01"
  nvke-cp-02: "00:16:3e:10:00:02"
  nvke-cp-03: "00:16:3e:10:00:03"
```

A node's MAC must be **globally administered**: the second-lowest bit of its
first byte clear (`00`, `04`, `08`, ... not `02`, `52`, `fe`). During the
bootstrap NVKE moves the node's NIC into an Open vSwitch bridge that takes over
its DHCP, and OVS copies the NIC's MAC to the bridge only when it is globally
administered. With QEMU's usual `52:54:00` the bridge asks for DHCP with a
random MAC, the node gets another address, and the bootstrap stalls. The
playbook refuses such a MAC for a node. NVKE pins the MAC itself only on nodes
configured with ifupdown, not with netplan as Ubuntu is.

Real servers are not affected: their NICs' burned-in MACs are globally
administered. Reserve those MACs in your DHCP server.

### The API VIP and BGP

NVKE runs kube-vip on every control-plane node in BGP mode only: ARP mode is
switched off in the node agent. Each node announces the VIP as a /32 from
AS 65100 to its default gateway, which must answer as AS 4294967000. Both
numbers are fixed in NVKE.

On libvirt's NAT network the gateway is the hypervisor, so `bgp_peer`
installs FRR there:

- only `zebra` and `bgpd` run (no `-l` listen address: in FRR 8 it also
  stops routes from reaching the kernel);
- sessions are passive, to the three node addresses only;
- only /32 routes inside `nvke_kvm_vip_prefix` (10.250.0.0/24) are accepted,
  and nothing is announced back;
- the VIP is installed as one ECMP route over the three nodes, and the
  hypervisor sends no ICMP redirects, so every packet takes that route;
- ufw (or firewalld) gets one rule per node for TCP 179 to 192.168.122.1.

The VIP must be **outside** the node subnet: on 192.168.122.0/24 the VMs
would ARP for it and nobody would answer.

```shell
sudo vtysh -c 'show bgp summary'      # three neighbors, state Established, 1 prefix each
ip route show 10.250.0.10             # nexthop via .101, .102 and .103
```

The VIP answers from the hypervisor and from the VMs on the libvirt network.
Other networks on the hypervisor (Docker bridges, VPNs, a second libvirt
network) are rejected by libvirt's own forwarding rules for `virbr0`.

With `nvke_kvm_bridge` set (VMs bridged onto your LAN), there is no BGP peer
on the hypervisor: peer your LAN router with the nodes (AS 65100 to
AS 4294967000) and reserve the addresses in your DHCP server.

## SSH into the VMs

Every VM gets its own ed25519 keypair, generated on the controller in
`~/.ssh/nvke/` (`nvke_kvm_ssh_key_dir`). The login user is `ubuntu`, with
passwordless sudo and key login only; the node image accepts no passwords.

```shell
ssh -i ~/.ssh/nvke/nvke-bootstrap_ed25519 ubuntu@192.168.122.100
ssh -i ~/.ssh/nvke/nvke-cp-01_ed25519     ubuntu@192.168.122.101
ssh -i ~/.ssh/nvke/nvke-cp-02_ed25519     ubuntu@192.168.122.102
ssh -i ~/.ssh/nvke/nvke-cp-03_ed25519     ubuntu@192.168.122.103
```

Or add this to `~/.ssh/config` and use `ssh nvke-cp-01`:

```text
Host nvke-bootstrap
  HostName 192.168.122.100
Host nvke-cp-01
  HostName 192.168.122.101
Host nvke-cp-02
  HostName 192.168.122.102
Host nvke-cp-03
  HostName 192.168.122.103
Host nvke-*
  User ubuntu
  IdentityFile ~/.ssh/nvke/%n_ed25519
```

From another machine, jump through the hypervisor (the VMs are on its NAT
network); copy the keys there first:

```text
Host nvke-*
  ProxyJump admin@kvm1.example.com
```

`virsh console nvke-cp-01` shows the serial console (boot and kernel
messages); with no password login it is for watching, not for logging in.

Where to look on the VMs:

| What | Where |
|---|---|
| The bootstrap's log | `sudo tail -f /var/lib/nvke/nvke-mgmt/bootstrap.log` on `nvke-bootstrap` |
| The seed cluster while it runs | `sudo KIND_EXPERIMENTAL_PROVIDER=nerdctl kind get kubeconfig --name nvkectl-bootstrap` on `nvke-bootstrap` |
| SPIRE attestation of a node | `sudo journalctl -u spire-agent -f` on the node |
| The node agent | `sudo journalctl -u nvke-agent -f` on the node |
| kube-vip | `sudo crictl ps --name kube-vip` and `sudo crictl logs <id>` on a node |

## Sizes and counts

```yaml
nvke_kvm_node_count: 3                                     # 1, 3 or 5
nvke_kvm_node_size: {vcpus: 4, memory_mb: 8192, disk_gb: 40}
nvke_kvm_bootstrap_size: {vcpus: 4, memory_mb: 8192, disk_gb: 40}
nvke_kvm_vm_sizes: {nvke-cp-01: {vcpus: 8, memory_mb: 16384, disk_gb: 80}}
nvke_system_reserved_memory: 1Gi                           # NVKE's default is 16Gi
```

Sizes apply when a VM is created. The node count is fixed once the cluster is
bootstrapped: NVKE's management cluster does not add, remove or replace its
own nodes.

## Several hypervisors

List them under `kvm_hosts`. The nodes go round robin across them; the
bootstrap VM, the image build and the BGP peer stay on the first one, and the
image is copied to the others. Each hypervisor's NAT network is private to
it, so several hypervisors need `nvke_kvm_bridge` set to a bridge on a network
they share (and then a BGP peer on that network's router).

## Destroy

```shell
make kvm-destroy
# or
ansible-playbook playbooks/kvm_destroy.yml -e nvke_kvm_destroy_confirm=yes
```

It removes the VMs (domain, UEFI variables, TPM state, disk, seed), their DHCP
reservations, their old SSH host keys on the controller, and the exported
kubeconfig. The cluster's credentials directory (`~/.nvke/nvke-mgmt`) is
renamed to `~/.nvke/nvke-mgmt.destroyed-<time>`, not deleted: it holds the
only off-node copy of the etcd encryption key. The node image, the downloads
and the SSH keys stay, so the next run builds nothing; FRR stays configured
and simply has no sessions.
