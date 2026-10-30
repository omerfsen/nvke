# Existing hosts

`omerfsen.nvke.cluster` installs the management cluster on hosts you already
have. It follows NVKE's *Plan your installation*, *Prepare nodes* and
*Bootstrap the management cluster* pages; read them for your site.

## Requirements

From NVKE's docs:

- **Nodes**: an odd number (1, 3 or 5), all of one architecture, each with a
  TPM 2.0, booted from the NVKE node image (build it with
  `ansible-playbook omerfsen.nvke.image`, or `make -C os-image image-native`
  from the NVKE release). The image uses DHCP: reserve each node's address.
  Each node needs more memory than `nvke_system_reserved_memory` (16Gi by
  default).
- **Bootstrap host**: Linux (here: Ubuntu/Debian with systemd), run as root,
  reaching every node on TCP 15005 and the API address on 6443; every node
  reaches it on TCP 30081. It can be one of the nodes. It needs outbound access
  to GitHub, the Go module proxy, Docker Hub, `ghcr.io`, `registry.k8s.io`,
  `cgr.dev`, `go.temporal.io` and `spiffe.github.io`.
- **API VIP** with more than one node: an unused IPv4 address outside the node
  subnet and the pod and service networks, routed to the nodes over BGP. Each
  node announces it from AS 65100 to its default gateway, which peers as AS
  4294967000 (both fixed). Configure your router for that, or run
  `omerfsen.nvke.bgp_peer` on the gateway if it is a Linux host.
- **Networks**: pod and service networks that overlap neither each other nor
  the node network. NVKE's default pod network is `192.168.0.0/16`.

## Inventory

```yaml
all:
  vars:
    nvke_cluster_name: example-mgmt
    nvke_vip: 10.250.0.10
    nvke_trust_domain: mgmt.example.com
    nvke_pod_cidr: 10.244.0.0/16          # if the nodes are in 192.168.0.0/16
    nvke_system_reserved_memory: 16Gi
    # Your own SPIRE CA (files on the controller); omit both to generate one.
    nvke_spire_ca_cert_file: ~/pki/spire-ca.crt
    nvke_spire_ca_key_file: ~/pki/spire-ca.key
  children:
    nvke_bootstrap:
      hosts:
        bootstrap: {ansible_host: 10.0.10.10}
    nvke_nodes:
      hosts:
        cp-01: {ansible_host: 10.0.10.2}
        cp-02: {ansible_host: 10.0.10.3}
        cp-03: {ansible_host: 10.0.10.4}
```

`nvke_node_ip` sets a node's address in the site spec when it differs from
`ansible_host`; `nvke_node_name` its name.

```shell
ansible-galaxy collection install omerfsen.nvke
ansible-playbook -i inventory.yml omerfsen.nvke.cluster
```

## Node user data

NVKE's way is to boot the nodes with cloud-init user data that points SPIRE
at the bootstrap host and installs the staged packages. The playbook writes
that user data to `~/.nvke/<cluster>/node-user-data.yaml` on the controller
after preparing the bootstrap host. To provision the nodes with it:

1. Prepare only the bootstrap host:
   `ansible-playbook -i inventory.yml omerfsen.nvke.cluster --tags bootstrap_host`.
2. Boot the nodes from the image with `node-user-data.yaml`, plus your own
   `users:` entry with an SSH key and passwordless sudo for Ansible.
3. Run the playbook again without `--tags`.

Nodes already booted without it work too: the `node` entry point writes the
same files, restarts the SPIRE agent and installs the same packages, then runs
the same checks.

## The VIP on your network

kube-vip peers with each node's default gateway. On a router, accept BGP
sessions from the node addresses as AS 4294967000 with remote AS 65100, accept
only /32 routes inside your VIP range, install them with ECMP (multipath), and
announce nothing back. `roles/bgp_peer/templates/frr.conf.j2` is a working FRR
configuration to copy. Disable ICMP redirects on that gateway if hosts on the
nodes' own subnet reach the VIP through it.

## Reruns

The playbook is idempotent. A cluster whose kubeconfig on the bootstrap host
answers is never bootstrapped again; a failed bootstrap has to be cleaned up
first (see [Troubleshooting](troubleshooting.md)). The management cluster
cannot add or replace nodes: NVKE does not support that.
