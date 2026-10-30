# omerfsen.nvke.libvirt_vm

Creates one UEFI VM on a libvirt/KVM host from a qcow2 already on the host (such
as the NVKE node image) or a downloaded cloud image, with:

- a fixed MAC (given, or a prefix plus three bytes derived from the name);
- its address from a DHCP reservation added to the libvirt network (stale
  leases on that address released), or from a static cloud-init network config;
- an optional TPM 2.0 (swtpm, TIS);
- optional PCI passthrough of devices already bound to vfio-pci (a GPU),
  with `managed='no'` so libvirt never detaches a device from a host driver;
- an ed25519 keypair generated on the controller, and extra cloud-config
  (`libvirt_vm_cloud_config`) for the first boot.

Idempotent; an existing VM is never changed. Runs as root on a Debian/Ubuntu
KVM host and installs what it needs.

```yaml
- hosts: kvm1
  become: true
  roles:
    - role: omerfsen.nvke.libvirt_vm
      vars:
        libvirt_vm_name: nvke-cp-01
        libvirt_vm_ip: 192.168.122.101
        libvirt_vm_mac: "00:16:3e:7a:00:65"
        libvirt_vm_image_path: /var/lib/libvirt/images/nvke-node-non-fde-ubuntu-26.04.1-amd64-v0.22.0.qcow2
        libvirt_vm_tpm: true
```

Variables: `ansible-doc -t role omerfsen.nvke.libvirt_vm`.
