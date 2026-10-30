# omerfsen.nvke.nvke

Bootstraps an NVIDIA Kubernetes Engine (NVKE) management cluster, following
NVKE's *Prepare nodes* and *Bootstrap the management cluster* pages. Three
entry points, run in this order:

| Entry point | Runs on | Does |
|---|---|---|
| `bootstrap_host` | the bootstrap host | Standalone nerdctl/containerd/buildkitd, kind, kubectl, clusterctl, Helm and Go at NVKE's pins; `nvkectl` and the two seed-cluster images from the pinned release; the site's SPIRE CA; the nodes' first-boot user data |
| `node` | every node (built from the NVKE node image) | SPIRE pointed at the bootstrap host, Kubernetes and OVN-Kubernetes packages, the docs' Verify checks, the TPM endorsement-key thumbprint |
| `site` | the bootstrap host | `nvkectl bootstrap site` once, the Verify checks, the kubeconfig and keys to the controller |

```yaml
- hosts: nvke_bootstrap[0]
  become: true
  tasks:
    - ansible.builtin.include_role: {name: omerfsen.nvke.nvke, tasks_from: bootstrap_host}
- hosts: nvke_nodes
  become: true
  tasks:
    - ansible.builtin.include_role: {name: omerfsen.nvke.nvke, tasks_from: node}
      vars:
        nvke_spire_trust_bundle: "{{ hostvars[groups['nvke_bootstrap'][0]].nvke_spire_ca_cert_pem }}"
- hosts: nvke_bootstrap[0]
  become: true
  tasks:
    - ansible.builtin.include_role: {name: omerfsen.nvke.nvke, tasks_from: site}
```

The playbook `omerfsen.nvke.cluster` does exactly this. Variables:
`ansible-doc -t role omerfsen.nvke.nvke`, or
[docs/variables.md](https://github.com/omerfsen/nvke/blob/main/docs/variables.md).
