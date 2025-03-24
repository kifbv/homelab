# What is it?
kubernetes homelab on raspberry pi 5
characteristics:
- armbian OS (Linux for ARM development boards)
- kubeadm installed kubernetes cluster
- cri-o container runtime
- cilium CNI
- gitops with Flux

# Pre-requisites
- `age` and `sops` 

# Installation
1. Build the Raspberry Pi image
For this, run the `Armbian Build` workflow. This will produce an Armbian image with all the necessary components already installed.
1. Configure the Raspberry Pi image
Before burning the image to the target storage (most probably SD-Card or NVME disk), it needs to be configured for the target node (i.e. controlplane, node01, node02...). This is done with the `configure-image.sh` script.
1. Bootstrap Kubernetes with kubeadm

1. create a key pair for encrypting secrets:
`mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/key.txt`
(storing the key in the default location where sops is expecting the key to be)

1. add sops config file at root of repo in `.sops.yaml`:
```yaml
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: '(^data|stringData)$'
    age: <age_public_key>
```

1. store the private key in a kubernetes secret for flux to use when decrypting secrets before sending them to kubernetes:
`kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt`
- create a github pat token with the following repo rights: admin (RW), contents (RW)
- bootstrap flux (it will ask for the token):
flux bootstrap github   --components-extra image-reflector-controller,image-automation-controller --token-auth=false   --owner=kifbv   --repository=homelab   --branch=main   --path=kubernetes/rpi-cluster/config   --personal
- create an age key (needs age): age -o age.agekey
- create encryption config file at the root of the repo ([docs](https://getsops.io/docs/#using-sopsyaml-conf-to-select-kms-pgp-and-age-for-new-files)) in .sops.yaml:
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: '^(data|stringData)$'
    age: <age_public_key>


Notes:
- metrics-server: add serverTLSBootstrap: true to the kubelets' config files (and verify that rotateCertificates: true), restart kubelet, accept the CSRs => this will ensure that the kubelet has certificates signed by the cluster's CA (i.e. this avoids starting the metrics-server pods with the --kubelet-insecure-tls flag)
To avoid doing this post kubeadm install see [here](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs) IMPORTANT: the CSR for these certificates have to be manually approved.
kubeadm init (controlplane)
--control-plane-endpoint=cluster-endpoint (needs DNS record 192.168.1.10  cluster-endpoint (PiHole))
--skip-phases addon/kube-proxy (use Cilium for that)
--token=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 6).$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16)
--pod-network-cidr 172.16.0.0/16
--service-cidr 10.96.0.0/12

Kubernetes cluster creation
1. Create a base image with `Armbian Build` workflow
This will produce an Armbian image (Debian based for ARM based SBCs) with the following components installed:
- kubeadm, kubelet, kubectl, cri-o
1. Download that image from the releases page
1. Run the `configure-image.sh` script
1. Copy the image to the SD-Card or NVMe disk
1. Plug the Pis into your network and turn them on
1. Go back to your desk and run watch-me.sh. The nodes will report to this node when they are ready.

GitOps

Add variables to action (os, target board...)


Github Action
Settings>Actions>General>Workflow permissions:Read and write permissions (todo: add permission contents: write to the workflow directly)
