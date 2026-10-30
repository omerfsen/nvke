# How it works

The collection follows NVIDIA's NVKE installation docs
(<https://docs.nvidia.com/nvke>) for the pinned release, step by step, and
reads the NVKE repository only where the docs leave a question open. This
page walks through the steps in the order they run, with the docs page each
one comes from.

NVKE's docs split an installation into seven steps. This release does the
first three, and adds GPU nodes; the rest need the management plane and
NVIDIA Infra Controller (NICo), which come later.

| Docs step | What | Here |
|---|---|---|
| 1. Build | Build the reference node OS image | `node_image` |
| 2. Prepare nodes | Boot the nodes from it with cloud-init user data, record their TPM thumbprints | `libvirt_vm` + `nvke` (`bootstrap_host`, `node`) |
| 3. Bootstrap | `nvkectl bootstrap site` forms the management cluster | `nvke` (`site`) |
| 4-7 | Management plane, NICo, API security, workload clusters | not yet |
| GPU runtime | The NVIDIA GPU Operator, as AICR installs it | `gpu_passthrough`, `libvirt_vm`, `gpu_operator` |

## The release

Everything is built from one NVKE release, `v0.22.0`, and the tag must
resolve to commit `400c24fb`: a moved tag fails the run instead of building
something else. NVKE publishes no node image and no bootstrap container
images, so both are built from that checkout, as the docs do. Every
downloaded tool is pinned to NVKE's own version and checksum
(`make/tool-versions.mk` in the repository).

## 1. The node image

Docs: *Build and host node OS images*.

On the build host (on KVM, the first hypervisor):

```shell
make -C os-image image-native ARCH=amd64 VARIANT=non-fde
make -C os-image boot-smoke REQUIRE_ACCELERATION=1
```

`image-native` installs Ubuntu 26.04.1 with the `linux-nvidia` kernel from the
server ISO in a QEMU VM with Packer, then installs `nvke-agent`, `spire-agent`,
NVIDIA's DOCA Open vSwitch, and stages the Kubernetes (`nvke-kubeadm-distro-*`)
and OVN-Kubernetes packages in a local apt repository on the image,
`/usr/lib/nvke/debs`. Nodes install them from there without network access.
`boot-smoke` boots a copy and checks the image contract. The role installs Go
1.27.3 and Packer 1.15.4 in its build directory, not system-wide, and runs
the build from its own clean checkout (the build refuses a modified one).

The image is not a ready Kubernetes node: it has no Kubernetes installed, only
staged. It uses DHCP on every `e*` interface and ignores cloud-init network
configuration, accepts SSH keys only, and is UEFI only.

## 2. The bootstrap host

Docs: *Bootstrap the management cluster*, "Before you begin" and "Install
nvkectl".

The bootstrap host runs `nvkectl`, which forms the cluster from a temporary
**seed cluster** (kind) on this host. The docs require rootful `nerdctl` with
containerd (Docker is not supported), `kind`, `helm`, `kubectl`, `clusterctl`,
Go and Make, run as root. The role installs:

- `nerdctl-full` 2.3.5 (containerd, buildkitd, CNI plugins) as a standalone
  runtime: its own `containerd-nerdctl` and `buildkit-nerdctl` units, socket and
  data root, so a Docker or Kubernetes containerd on the same host is never
  touched. `/etc/nerdctl/nerdctl.toml` names that socket and sets
  `cni_netconfpath = "/etc/containerd-nerdctl/net.d"`, as the docs require.
- kind v0.32.0, kubectl v1.36.0, clusterctl v1.13.6, Helm v4.2.4, Go 1.27.3.
- `nvkectl`, built with `make -C cli build` (the docs: not `go build`, the
  Makefile stamps the version and the Cluster API version into it).
- The two seed-cluster images, built with `make -C cli images` and tagged with
  the release (`nke-controller:v0.22.0`,
  `cluster-api-provider-provisioned:v0.22.0`), passed to the bootstrap with
  `--nvke-controller-image` and `--provisioned-provider-image`.

### The SPIRE CA and the node user data

Docs: *Plan your installation*, "Identity and trust"; *Prepare nodes*.

Nodes built from the image attest to SPIRE with their TPM, and can only trust
a CA they are given in advance, so the site needs its own SPIRE CA. Bring one
(`nvke_spire_ca_cert_file`, `nvke_spire_ca_key_file`), or the role generates
an ECDSA P-256 CA on the bootstrap host, the same kind NVKE's own tests use.

From the CA and the bootstrap host's address the role builds the nodes'
first-boot user data exactly as *Prepare nodes* writes it:

```yaml
#cloud-config
write_files:
  - path: /etc/nke/spire.env
    permissions: "0600"
    content: |
      SPIRE_SERVER_ADDRESS=<bootstrap host>
      SPIRE_SERVER_PORT=30081
      SPIRE_TRUST_DOMAIN=<trust domain>
  - path: /etc/nke/trust-bundle.pem
    permissions: "0644"
    content: <SPIRE CA certificate>
runcmd:
  - DEBIAN_FRONTEND=noninteractive apt-get install -y nvke-kubeadm-distro-1.36.3
  - DEBIAN_FRONTEND=noninteractive apt-get install -y nvke-cni-ovn-images-2.4.2 nvke-cni-ovn-charts-2.4.2
```

It is saved on the controller as `~/.nvke/<cluster>/node-user-data.yaml`, for
your own provisioning system. This is why the bootstrap host comes first: the
nodes need its address and the CA at their first boot.

## 3. The nodes

Docs: *Prepare nodes*.

On KVM each node boots from the image with that user data, a TPM 2.0 (swtpm)
and a DHCP reservation for its fixed MAC. On first boot cloud-init writes the
SPIRE files, the image renders `/etc/spire-agent/agent.conf` from them, and
`runcmd` installs the packages from the image's local repository. The SPIRE
agent then retries until the bootstrap's SPIRE server answers; until then
`nvke-agent` keeps restarting, which the docs call expected.

The `node` entry point then runs the docs' Verify list on every node:
`cloud-init status` is `done`, the packages are installed, `kubeadm version`
is `v1.36.3`, `ovs-vsctl show` works, `agent.conf` names the bootstrap host,
port 30081 and the trust domain, and `spire-agent` is active. It reads each
node's TPM endorsement-key thumbprint with `get_tpm_pubhash`. On a node that
was booted without the user data it writes the same files and installs the
same packages first.

## 4. The VIP

Docs: *Plan your installation*, "Network".

With more than one node the API needs a VIP, and NVKE announces it with
kube-vip over BGP only: every control-plane node advertises the VIP from AS
65100 to its default gateway, which must answer as AS 4294967000. On KVM that
gateway is the hypervisor, and `bgp_peer` runs FRR there; see
[KVM/libvirt](kvm.md#the-api-vip-and-bgp). The VIP must be off the node
subnet.

## 5. The bootstrap

Docs: *Bootstrap the management cluster*.

On the bootstrap host, in `/var/lib/nvke/<cluster>/`:

```shell
# hosts.csv: name,ip,tpm_ek_thumbprint, one row per node
nvkectl generate sitespec <cluster> --nodes hosts.csv \
  --set cluster.k8sVersion=1.36.3 \
  --set cluster.controlPlaneVIP=<vip> \
  --set cluster.podCidr=<pod cidr> \
  --set cluster.serviceCidr=<service cidr> \
  --set cluster.kubeletConfig.systemReservedMemory=<memory> \
  --set spire.trustDomain=<trust domain> \
  --set spire.upstreamCA=true > sitespec.yaml
export NVKECTL_SPIRE_CA_CERT_FILE=... NVKECTL_SPIRE_CA_KEY_FILE=...
nvkectl bootstrap site -f sitespec.yaml --dry-run
nvkectl bootstrap site -f sitespec.yaml --nvke-controller-image ... --provisioned-provider-image ... --timeout 45m
```

`nvkectl` creates the seed cluster, installs SPIRE, Cluster API and a copy of
the NVKE management plane in it, and requests the cluster. The seed's SPIRE
server (port 30081 on the bootstrap host) attests each node by its TPM
thumbprint; `nvke-agent` then starts on the node, and the seed's controller
drives `kubeadm init` on one node and control-plane joins on the others
through it, with no SSH. Every node becomes a control-plane node. At the end
`nvkectl` removes the control-plane `NoSchedule` taint (the management plane
runs on these nodes), saves the outputs and deletes the seed cluster. A run
whose kubeconfig already answers is never repeated.

During the bootstrap NVKE moves each node's NIC into an Open vSwitch bridge
that takes over its address. See [MAC addresses](kvm.md#mac-addresses) for why
VMs need globally administered MACs.

The docs' Verify list then runs: every node is `Ready`, no control-plane
taint is left, the seed cluster is gone.

## 6. The outputs

| File | Where | What |
|---|---|---|
| `<cluster>.kubeconfig` | bootstrap host, and on the controller as `~/.kube/<cluster>.yaml` | Break-glass admin kubeconfig (client certificate in `nvke:breakglass`, bound to `cluster-admin`, one year) |
| `<cluster>-etcd-encryption-key.json` | controller, `~/.nvke/<cluster>/`; removed from the bootstrap host | The only copy of the etcd encryption key that is not on a node |
| `spire-ca.crt`, `spire-ca.key` | controller, `~/.nvke/<cluster>/`; bootstrap host | The site's SPIRE CA; later installs need it |
| `clusterstaticentry-crd.yaml`, `clusterstaticentries.yaml` | controller, `~/.nvke/<cluster>/` | SPIRE registrations exported from the seed |
| `node-user-data.yaml` | controller, `~/.nvke/<cluster>/` | The nodes' first-boot user data |

Keep `~/.nvke/<cluster>/` safe: the docs ask for the kubeconfig and the key
file to go to secure storage.

## 7. GPU nodes

Docs: *Build and verify your own node image* ("`nvke-agent` installs
Kubernetes later, and the NVIDIA GPU Operator installs GPU drivers"); *What
is NVKE* (the accelerated runtime comes from NVIDIA AI Cluster Runtime,
AICR).

A GPU node is an NVKE node like the others, booted from the node image; the
GPU Operator gives it the driver. NVKE's GPU nodes normally come from NICo
into workload clusters. Without NICo, on KVM, a management-cluster node VM
gets the GPU:

- **The hypervisor** (`gpu_passthrough`): the GPU and every function in its
  IOMMU group are bound to vfio-pci from the initrd, the host NVIDIA and
  nouveau drivers are kept from loading, and one reboot applies it. Nothing
  is ever detached from a running driver.
- **The VM** (`libvirt_vm`, `libvirt_vm_hostdevs`): the functions are
  attached with `managed='no'`, so libvirt fails the start rather than take a
  device from a host driver.
- **The GPU Operator** (`gpu_operator`), from the bootstrap host: the chart
  version AICR pins (`v26.7.2`, checksum verified), the toolkit values of
  AICR's NVKE recipe (`RUNTIME_CONFIG_SOURCE=file`: NVKE's containerd 2.3
  has a version 3 config that the toolkit's default source would see as
  version 4, and its drop-in would then stop containerd; and no GPU through
  `NVIDIA_VISIBLE_DEVICES` in unprivileged pods), and the chart's default
  driver, `595.91.07`. AICR holds `580.173.02` for AWS EFA only, and that
  driver has no Ubuntu 26.04 image.

The checks: the ClusterPolicy is `ready`, the cluster offers the expected
`nvidia.com/gpu` count, and a CUDA vectorAdd pod (image pinned by digest)
passes on a GPU and is deleted again.

## What the management cluster is not

The docs' known limitations apply: the management cluster does not upgrade,
scale or replace its own nodes, and NVKE has no backup or restore procedure
for it. It is a plain Kubernetes cluster until the management plane is
installed on it.
