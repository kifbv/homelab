# Homelab :house:

Kubernetes homelab on Raspberry Pi 5

## Features

- [Armbian OS](https://www.armbian.com/) (Linux for ARM development boards).
- [kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/) installed Kubernetes cluster.
- [CRI-O](https://github.com/cri-o/cri-o/tree/main) container runtime.
- [Cilium](https://www.cilium.io/) CNI.
- GitOps with [Flux](https://fluxcd.io/).

## Pre-requisites

- [age](https://github.com/FiloSottile/age) and [sops](https://github.com/getsops/sops) for storing encrypted secrets in this repo
- one or more Raspberry Pi 5 boards

## Installation

### Create the cluster

1. Build the Raspberry Pi image

For this, run the `Build Armbian Image` workflow.

This will produce an Armbian image (Debian based for ARM SBCs) with all the necessary components for a **controlplane** or **worker** node already installed (kubeadm, kubelet, kubectl, cri-o).

The image is customized thanks to the `userpatches/customize-image.sh` script.

I am using a slightly modified version of the original workflow, with the following extra arguments but you can use the original `armbian/build` action if you prefer.
  - `CONSOLE_AUTOLOGIN=no` to avoid automatically login as root for local consoles at first run.
  - `EXTRAWIFI=no` to not include extra wifi drivers.

2. Configure the Raspberry Pi image(s)

Before burning the image to the target storage, it needs to be configured for the target node (i.e. controlplane, node01, node02...).

This is done with the `configure-image.sh` script and is similar to what can be achieved with the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).

Run that script with `sudo configure-image.sh to see the usage.

3. Boot your Pi

The previous script will give you the command to run (you will find the path to your device with e.g. `lsblk`).

Once the medium is ready, connect it to your Pi, plug it into your switch and power it on.

Each Pi will boot and execute specific commands in order to init or join a cluster. This is done with some systemd services running at boot time (see `scripts/configure-image.sh`).

4. Update your router's config

After the `controlplane` node has booted, quickly add a DHCP reservation for it with the name `controlplane`. Hurry up, you have 4 minutes until `kubeadm` aborts the installation.

This DHCP reservation is required because we passed the `--control-plane-endpoint` option to `kubeadm init`. This option gives kubernetes a fixed DNS name for the cluster endpoint and allows to update to an HA cluster in the future.

_TODO: add logic for workers and subsequent controlplanes_
_TODO: add cilium install script_

5. Add other nodes to the cluster

You can now add extra nodes by repeating steps 2 and 3 above.

- controlplane nodes: as a safeguard, uploaded-certs will be deleted in two hours. If necessary, you can use `kubeadm init phase upload-certs --upload-certs` to reload certs afterward to add controlplane nodes.
- worker nodes: the initial token is valid for 24h. If necessary, you can use `kubeadm token create --print-join-command` to regenerate a join command.

## Configuration

Now that the cluster is up and running, it's time to bootstrap `flux` which will install all the apps in the cluster.

### Prepare the SOPS stuff

Before bootstrapping flux we need to set the stage for storing secrets inside the repo.

Other solutions include Hashicorp Vault, Azure Key Vaults, AWS KMS, etc but this simpler and good enough for me.

1. Create a key pair for encrypting secrets:

`mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/key.txt`

This creates and store an age key in the default location where sops is expecting it.

2. Add sops config file at root of repo in `.sops.yaml`:

```bash
cat <<-EOF> $(git rev-parse --show-toplevel)/.sops.yaml
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: '(^data|stringData)$'
    age: $(cat ~/.config/sops/age/keys.txt | grep 'public key' | tr -s ' ' | cut -f4 -d' ')
EOF
```

3. Store the age private key in a Kubernetes secret for flux to use when decrypting secrets before sending them to Kubernetes:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

### Bootstrap Flux

1. create a github pat token with the following repo rights: admin (RW), contents (RW)

2. bootstrap flux (it will ask for the token):

```bash
flux bootstrap github  \
  --components-extra image-reflector-controller,image-automation-controller \
  --token-auth=false \
  --owner=<your_gh_name> \
  --repository=homelab \
  --branch=main \
  --path=kubernetes/rpi-cluster/config \
  --personal
```

Notes:
- metrics-server: add serverTLSBootstrap: true to the kubelets' config files (and verify that rotateCertificates: true), restart kubelet, accept the CSRs => this will ensure that the kubelet has certificates signed by the cluster's CA (i.e. this avoids starting the metrics-server pods with the --kubelet-insecure-tls flag)
To avoid doing this post kubeadm install see [here](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs) IMPORTANT: the CSR for these certificates have to be manually approved.
