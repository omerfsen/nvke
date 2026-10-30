# Troubleshooting

NVKE's own guide is *Troubleshoot* in its docs, and
`cli/docs/bootstrap-troubleshooting.md` in the repository. These are the
problems met while building this collection, and how to recognise them.

## The bootstrap stays at "Provisioning"

`/var/lib/nvke/<cluster>/bootstrap.log` on the bootstrap host shows
`cluster state ... status=Provisioning` for many minutes. In the seed cluster:

```shell
sudo -i
export KIND_EXPERIMENTAL_PROVIDER=nerdctl
kind get kubeconfig --name nvkectl-bootstrap > /tmp/seed.kubeconfig
kubectl --kubeconfig /tmp/seed.kubeconfig get machines -A
```

One node `Ready` and the others `uninitialized` (in `journalctl -u
nvke-agent` on them) means the joining nodes cannot reach the API through the
VIP. Check, in this order:

1. **The nodes kept their addresses.** `virsh domifaddr <node>` or `ip -br a`
   on the node: the address now sits on an Open vSwitch bridge (`brenp1s0`)
   and must still be the reserved one. If a node moved to an address from the
   DHCP range, its MAC is locally administered; see
   [MAC addresses](kvm.md#mac-addresses).
2. **The VIP route is installed.** On the BGP peer:
   `vtysh -c 'show bgp summary'` (sessions Established, one prefix each) and
   `ip route show <vip>` (nexthops via the nodes). A prefix in BGP but no
   kernel route means bgpd runs with `-l`: in FRR 8 a listen address also
   turns off route installation. `bgp_peer` does not set it.
3. **The API answers on the VIP** from the bootstrap host:
   `curl -k https://<vip>:6443/readyz`.

## Retrying a failed bootstrap

From NVKE's *Bootstrap the management cluster*, "If the bootstrap fails":

1. If the error says the etcd encryption key was not saved, run the save
   command it prints first.
2. Delete the seed cluster:
   `KIND_EXPERIMENTAL_PROVIDER=nerdctl kind delete cluster --name nvkectl-bootstrap`
   (without the prefix kind looks in Docker and deletes nothing).
3. On every node that has `/etc/kubernetes/manifests`: `kubeadm reset -f`.
4. Delete `/var/lib/nvke/<cluster>/<cluster>-etcd-encryption-key.json` if the
   failed run left one; the bootstrap never overwrites it.
5. Run the playbook again.

On KVM it is usually quicker to destroy the VMs and run `kvm.yml` again.

## `nvke-agent` fails to start on a node before the bootstrap

Expected. It waits for the SPIRE agent's workload API, which exists only once
the bootstrap's SPIRE server has attested the node. It restarts on its own
until then.

## A rebuilt VM does not get its reserved address

dnsmasq does not hand a reserved address to a new MAC while an older lease
for it is alive (an hour on libvirt):

```text
not using configured address 192.168.122.101 because it is leased to 52:54:00:...
```

`kvm_destroy` releases the leases of the VMs it removes, and `libvirt_vm`
releases a stale lease on its address when no defined VM holds that MAC. By
hand: `dhcp_release virbr0 <ip> <mac>` (package `dnsmasq-utils`).

## SSH to a node hangs

The node changed address (see above), or it is rebooting. `virsh console
<node>` shows its serial console.

## `apt-get update` fails on the build host

A broken third-party apt source on the host fails a cache refresh. The roles
refresh the apt cache only when a package they need is missing, so a host
that already has them is not affected.

## Variables from `group_vars/all.yml` are ignored

With a `group_vars/all/` directory present, Ansible reads that and not
`group_vars/all.yml`. This repository keeps its KVM defaults in
`inventory/kvm/group_vars/all/defaults.yml`; put overrides in
`inventory/kvm/group_vars/all/local.yml` (files load in name order, so
`local.yml` wins).

## Logs

| What | Where |
|---|---|
| Image build | `<node_image_build_dir>/build-<image>.log` on the build host |
| Bootstrap | `/var/lib/nvke/<cluster>/bootstrap.log` on the bootstrap host; diagnostics of a failed run in `/var/lib/nvke/<cluster>/cluster-diagnostics/` |
| Node agent | `journalctl -u nvke-agent` on the node |
| SPIRE agent | `journalctl -u spire-agent`, `journalctl -u nvke-spire-configure` on the node |
| BGP | `journalctl -u frr`, `vtysh -c 'show bgp summary'` on the BGP peer |

## The VMs have no internet access

The bootstrap VM cannot reach GitHub or the Ubuntu archive, while the host
can. Check libvirt's NAT rules for the network:

```shell
sudo iptables -S | grep LIBVIRT_FWO
sudo iptables -t nat -S | grep LIBVIRT_PRT
```

Rules with `-o <interface>` accept and masquerade only traffic leaving through
that interface. A network defined with `<forward dev='eno1' mode='nat'>` on a
host whose address and default route sit on a bridge with `eno1` as a port
(`br1`) rejects everything: traffic leaves through the bridge, not `eno1`.
Point the forward device at the interface of the default route, or drop it
(`<forward mode='nat'/>`, any interface), with `virsh net-edit default`, then
`virsh net-destroy default && virsh net-start default` while no VM uses it.

## A GPU node VM does not start

`virsh start` fails with a message about the PCI device. The VM gets the GPU
with `managed='no'`, so libvirt never takes it from a host driver: vfio-pci
must own it from boot. `lspci -nnk -s 01:00` on the host must say
`Kernel driver in use: vfio-pci` for every function; if it does not, run
`playbooks/gpu_passthrough.yml` and reboot the host.

## The GPU Operator never gets ready

`kubectl get clusterpolicy` stays `notReady`. Look at the driver pod on the GPU
node first:

```shell
kubectl -n gpu-operator get pods -o wide
kubectl -n gpu-operator logs -l app=nvidia-driver-daemonset -c nvidia-driver-ctr --tail=50
```

The driver container builds the module for the node's kernel, so the node
needs the Ubuntu archive, and a driver image for the node's Ubuntu release
must exist (`nvcr.io/nvidia/driver:<version>-ubuntu26.04`). If containerd
keeps restarting on the node after the toolkit starts, the toolkit wrote a
config drop-in at the wrong version: the role sets `RUNTIME_CONFIG_SOURCE=file`
for that.

