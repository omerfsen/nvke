# omerfsen.nvke.gpu_passthrough

Hands NVIDIA GPUs on a KVM host to VMs. An NVKE GPU node must boot the NVKE
node image, where the GPU Operator installs the driver, so on a KVM host the
GPU node is a VM and the GPU is passed through to it with VFIO.

- checks that the IOMMU is on and that each device's IOMMU group holds only
  the listed devices (a VM owns a whole group);
- `permanent`: keeps the host NVIDIA and nouveau drivers from loading, binds
  the devices to vfio-pci from the initrd, and fails until the host has been
  rebooted onto that binding;
- `off`: removes that configuration; the host driver takes the devices back
  after a reboot.

It never reboots the host, never detaches a device from a running driver (a
live detach can freeze the host) and never edits the bootloader. While the
GPU is on vfio-pci the host cannot use it, and a display attached to it stays
dark.

```yaml
- hosts: kvm1
  become: true
  roles:
    - role: omerfsen.nvke.gpu_passthrough
      vars:
        gpu_passthrough_devices: ["0000:01:00.0", "0000:01:00.1"]
```

Find the devices with `lspci -Dnn | grep -i nvidia`, and their group with
`readlink /sys/bus/pci/devices/0000:01:00.0/iommu_group`.

Variables: `ansible-doc -t role omerfsen.nvke.gpu_passthrough`.
