# omerfsen.nvke.node_image

Builds the NVKE reference node image (Ubuntu 26.04.1 or 24.04.5 with the
`linux-nvidia` kernel, `nvke-agent`, `spire-agent`, DOCA Open vSwitch, and the
Kubernetes and OVN-Kubernetes packages staged in a local repository) with the
NVKE repository's own recipe, as NVKE's *Build and host node OS images* page
does:

```shell
make -C os-image image-native ARCH=amd64 VARIANT=non-fde
make -C os-image boot-smoke REQUIRE_ACCELERATION=1
```

It installs Go and Packer (checksum verified) in its build directory, checks
out the pinned release (and refuses a tag that moved), and copies the image to
`node_image_dest_dir`. Nothing happens when that image already exists. Runs as
root on a Debian/Ubuntu host with KVM, of the image's architecture; the build
peaks at about 40 GiB in `node_image_build_dir`.

```yaml
- hosts: kvm1
  become: true
  roles:
    - role: omerfsen.nvke.node_image
      vars:
        node_image_build_dir: /data/nvke-build
        node_image_dest_dir: /var/lib/libvirt/images
```

Variables: `ansible-doc -t role omerfsen.nvke.node_image`.
