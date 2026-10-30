# omerfsen.nvke

Ansible collection for [NVIDIA Kubernetes Engine](https://docs.nvidia.com/nvke)
(NVKE), the open-source software an AI factory runs to offer managed
Kubernetes on its own GPU infrastructure. This release installs the
**management cluster**: it builds the NVKE reference node image, prepares
TPM-attested nodes, and runs `nvkectl bootstrap site` to form a highly
available cluster behind a BGP-announced API VIP. Rerun it any time; it only
changes what is missing.

It can also provision everything on KVM/libvirt: the node image, three Ubuntu
VMs with a TPM 2.0 each, a bootstrap VM, and a BGP peer on the hypervisor for
the VIP. With a GPU in the hypervisor, one node VM gets it through VFIO and
the NVIDIA GPU Operator gives it a driver.

NVKE itself is a preview: NVIDIA does not recommend it for production
workloads yet, and its APIs and behaviour can change between releases. This
collection pins one NVKE release and follows its documented install path. It
comes with no guarantee of any kind; see
[License and disclaimer](#license-and-disclaimer).

## Contents

| Name | Type | Does |
|---|---|---|
| `omerfsen.nvke.nvke` | role | Bootstrap host (`bootstrap_host`), node preparation (`node`), `nvkectl bootstrap site` and the kubeconfig (`site`) |
| `omerfsen.nvke.node_image` | role | Builds the NVKE reference node image (Ubuntu, nvke-agent, spire-agent) from a pinned release |
| `omerfsen.nvke.bgp_peer` | role | FRR on the nodes' gateway, installing the API VIP that kube-vip announces |
| `omerfsen.nvke.libvirt_vm` | role | One UEFI VM on libvirt/KVM, optionally with a TPM 2.0 and passed-through PCI devices, on a DHCP reservation or a static address |
| `omerfsen.nvke.gpu_passthrough` | role | Binds a hypervisor's GPU to vfio-pci from boot, for a GPU node VM |
| `omerfsen.nvke.gpu_operator` | role | The NVIDIA GPU Operator on the cluster (AICR's pinned version), proven with a CUDA pod |
| `omerfsen.nvke.cluster` | playbook | The management cluster on any inventory with groups `nvke_bootstrap` and `nvke_nodes` |
| `omerfsen.nvke.image` | playbook | The node image on the first `kvm_hosts` host |
| `omerfsen.nvke.kvm` | playbook | GPU passthrough, image, VMs and BGP peer on the `kvm_hosts`, then `cluster` and `gpu_operator` on them |
| `omerfsen.nvke.gpu_passthrough` | playbook | Bind each hypervisor's `nvke_kvm_gpu_devices` to vfio-pci |
| `omerfsen.nvke.gpu_operator` | playbook | The GPU Operator on the cluster, from the bootstrap host (`nvke_gpu_operator: true`) |
| `omerfsen.nvke.kvm_destroy` | playbook | Destroy those VMs (asks for confirmation) |

## Support matrix

| | Supported |
|---|---|
| NVKE | v0.22.0 (commit `400c24f`), pinned |
| Kubernetes | 1.36.3 (NVKE's supported version), OVN-Kubernetes 2.4.2 |
| Node OS | The NVKE reference node image: Ubuntu 26.04.1 (default) or 24.04.5, `linux-nvidia` kernel, amd64 or arm64 |
| Nodes | 1, 3 or 5, each a control plane with a TPM 2.0; a VIP with more than one |
| Bootstrap host | Ubuntu/Debian with systemd, amd64 or arm64; Docker may be present, it is not used |
| Image build host | Ubuntu/Debian with KVM, of the image's architecture |
| ansible-core | 2.16 or later |
| Provisioning | KVM/libvirt (one hypervisor on its NAT network, or several on a shared bridge) |
| GPU | NVIDIA GPU Operator v26.7.2 (the version AICR pins), driver 595.91.07; on KVM, one GPU passed through to a node VM with VFIO |
| Tested | NVKE v0.22.0, 3 nodes on Ubuntu 26.04.1 KVM VMs with swtpm TPM 2.0, BGP VIP via FRR on an Ubuntu 22.04 hypervisor: all Ready, rerun `changed=0`, VIP failover; one RTX 4080 SUPER passed through to a node VM on an Ubuntu 24.04 hypervisor: GPU Operator ready, CUDA, TensorFlow, PyTorch and TensorRT workloads pass, rerun `changed=0` |

## Quick start

### On KVM/libvirt

```shell
git clone https://github.com/omerfsen/nvke.git && cd nvke
make dev && source .venv/bin/activate
ansible-playbook playbooks/kvm.yml
export KUBECONFIG=~/.kube/nvke-mgmt.yaml
kubectl get nodes -o wide
```

The first run builds the node image (about 25 minutes), then creates the
bootstrap VM and the nodes and bootstraps the cluster (about 20 minutes).
The nodes are `nvke-cp-01` to `nvke-cp-03` on 192.168.122.101-103, the
bootstrap host `nvke-bootstrap` on .100, the API VIP 10.250.0.10. SSH:
`ssh -i ~/.ssh/nvke/nvke-cp-01_ed25519 ubuntu@192.168.122.101`.

### Existing hosts

Nodes must be built from the NVKE node image (`omerfsen.nvke.image` builds
it) and have a TPM 2.0. The bootstrap host is any Ubuntu/Debian host the nodes
can reach.

```shell
ansible-galaxy collection install omerfsen.nvke
```

```yaml
# inventory.yml
all:
  vars:
    nvke_vip: 10.250.0.10                 # routed to the nodes over BGP
    nvke_trust_domain: mgmt.example.com
  children:
    nvke_bootstrap:
      hosts:
        bootstrap: {ansible_host: 10.0.10.10}
    nvke_nodes:
      hosts:
        cp-01: {ansible_host: 10.0.10.11}
        cp-02: {ansible_host: 10.0.10.12}
        cp-03: {ansible_host: 10.0.10.13}
```

```shell
ansible-playbook -i inventory.yml omerfsen.nvke.cluster
```

## Documentation

- [How it works](https://github.com/omerfsen/nvke/blob/main/docs/how-it-works.md): every step, and why it is done that way
- [KVM/libvirt](https://github.com/omerfsen/nvke/blob/main/docs/kvm.md): the VMs, the network and the BGP peer, sizes, destroy
- [Existing hosts](https://github.com/omerfsen/nvke/blob/main/docs/existing-hosts.md): requirements, BGP for the VIP, your own SPIRE CA
- [Variables](https://github.com/omerfsen/nvke/blob/main/docs/variables.md): every variable, with defaults
- [Troubleshooting](https://github.com/omerfsen/nvke/blob/main/docs/troubleshooting.md)
- Role reference: `ansible-doc -t role omerfsen.nvke.<role>`
- [Build log](https://github.com/omerfsen/nvke/blob/main/docs/build-log.md): how this collection was built and tested

## Roadmap

- The NVKE management plane (Cluster API, CAPNICo, SPIRE, the NVKE API) on
  the management cluster
- GPU workload clusters through NICo (GPU nodes on the management cluster
  are done)
- Bare-metal provisioning next to `libvirt_vm`

## License and disclaimer

Licensed under the [Apache License 2.0](https://github.com/omerfsen/nvke/blob/main/LICENSE). The collection is provided
"AS IS", without warranties or conditions of any kind, and the authors accept
no liability for its use (sections 7 and 8 of the license). Test it on your
own systems before you rely on it.

This is an independent community project. It is not affiliated with, endorsed
or supported by NVIDIA. NVIDIA and NVKE are trademarks of their respective
owners.
