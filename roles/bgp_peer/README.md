# omerfsen.nvke.bgp_peer

NVKE's management cluster announces its API VIP with kube-vip over BGP only:
every control-plane node advertises the VIP as a /32 from AS 65100 to its
default gateway, which must peer as AS 4294967000. This role makes a Linux
gateway that peer with FRR:

- only `zebra` and `bgpd`; passive sessions to the listed nodes only;
- accepts only /32 routes inside `bgp_peer_vip_prefixes`, announces nothing;
- installs the VIP as one ECMP route over the nodes, and turns off ICMP
  redirects so hosts on the nodes' subnet keep using it;
- opens TCP 179 from each node in ufw or firewalld;
- refuses to replace an FRR configuration it did not write.

```yaml
- hosts: kvm1
  become: true
  roles:
    - role: omerfsen.nvke.bgp_peer
      vars:
        bgp_peer_address: 192.168.122.1
        bgp_peer_neighbors: [192.168.122.101, 192.168.122.102, 192.168.122.103]
        bgp_peer_vip_prefixes: [10.250.0.0/24]
```

Variables: `ansible-doc -t role omerfsen.nvke.bgp_peer`.
