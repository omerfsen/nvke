# omerfsen.nvke.gpu_operator

Installs the NVIDIA GPU Operator on an NVKE cluster. NVKE's node image
carries no GPU driver: the GPU Operator builds and loads it on each GPU node,
and installs the container toolkit and the device plugin.

- the chart version NVIDIA AI Cluster Runtime (AICR) pins, `v26.7.2`,
  downloaded once and checksum verified;
- the toolkit values AICR's NVKE recipe uses: the toolkit reads containerd's
  `config.toml` itself (NVKE's containerd 2.3 has a version 3 config that the
  default config source would migrate, breaking containerd), and only a
  `nvidia.com/gpu` request gives a pod a GPU;
- the chart's default driver, `595.91.07`, which has an Ubuntu 26.04 image;
- installed or upgraded only when the release's chart or values differ;
- then waits for every operand, checks the GPUs are allocatable, and runs a
  CUDA vectorAdd pod on one GPU (deleted afterwards).

Runs on a host with helm, kubectl and the cluster's admin kubeconfig: the
NVKE bootstrap host has all three.

The CUDA pod runs on every run and needs a free GPU: on a cluster whose GPUs
are all taken it waits up to ten minutes and fails. Set
`gpu_operator_smoke_test: false` there.

```yaml
- hosts: nvke_bootstrap[0]
  become: true
  roles:
    - role: omerfsen.nvke.gpu_operator
      vars:
        gpu_operator_kubeconfig: /var/lib/nvke/nvke-mgmt/nvke-mgmt.kubeconfig
```

Variables: `ansible-doc -t role omerfsen.nvke.gpu_operator`.
