# 🏠 Homelab - Kubernetes on Raspberry Pi 5

A complete Kubernetes homelab setup running on Raspberry Pi 5 boards with GitOps and self-healing capabilities.

## ✨ Features

- 🐧 [Armbian OS](https://www.armbian.com/) - Optimized Linux for ARM boards
- ☸️ [kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/) - Production-grade Kubernetes installation
- 🐳 [CRI-O](https://github.com/cri-o/cri-o/tree/main) - Lightweight container runtime
- 🔄 [Cilium](https://www.cilium.io/) - eBPF-based networking, observability, and security
- 🚢 [Flux](https://fluxcd.io/) - GitOps continuous delivery solution

## 📋 Requirements

- 🔐 [age](https://github.com/FiloSottile/age) and [sops](https://github.com/getsops/sops) - For storing encrypted secrets in the repository
- 🚢 [flux CLI](https://fluxcd.io/docs/installation/) - To inspect and manage the Flux installation (optional)
- 🔄 [cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli) - To inspect and manage the Cilium installation (optional)
- 🍓 One or more Raspberry Pi 5 boards with at least 8GB RAM recommended
- 🧠 microSD cards (32GB+ recommended) or USB/NVMe storage

## 🚀 Installation

### 🔐 Setting Up Secret Management with SOPS

> ⚠️ **IMPORTANT**: You must set up SOPS **BEFORE** running the configure-image.sh script, as the script expects the SOPS key to already exist.

#### 1. 🔑 Create an Age Key Pair

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

This creates an Age key in the default location where SOPS will look for it.

#### 2. 📄 Configure SOPS for the Repository

Create a `.sops.yaml` configuration file at the root of your repository:

```bash
cat <<-EOF> $(git rev-parse --show-toplevel)/.sops.yaml
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: '(^data|stringData)$'
    age: $(cat ~/.config/sops/age/keys.txt | grep 'public key' | tr -s ' ' | cut -f4 -d' ')
EOF
```

### Creating the Kubernetes Cluster

#### 1. 🔨 Build the Raspberry Pi Image

Run the `Build Armbian Image` GitHub workflow to create a custom Armbian image with:
- Kubernetes components pre-installed (kubeadm, kubelet, kubectl)
- CRI-O container runtime
- All necessary dependencies for both control plane and worker nodes

The image is customized through the `userpatches/customize-image.sh` script with these optimizations:
- `CONSOLE_AUTOLOGIN=no` - Improved security by disabling automatic root login
- `EXTRAWIFI=no` - Smaller image by excluding unnecessary WiFi drivers

#### 2. ⚙️ Configure the Image

Before burning the image to your microSD card or storage device, you need to configure it for the specific node role:

```bash
# Show usage information
sudo ./scripts/configure-image.sh --help

# Example for the main control plane node
sudo ./scripts/configure-image.sh --image Armbian.img --hostname controlplane --ssh-key ~/.ssh/id_ed25519.pub --password yourpassword

# Example for a worker node
sudo ./scripts/configure-image.sh --image Armbian.img --hostname worker0 --ssh-key ~/.ssh/id_ed25519.pub --password yourpassword
```

The script supports these hostname patterns:
- `controlplane` - The main control plane node (only one)
- `controlplane[0-9]` - Additional control plane nodes (for HA setups)
- `worker[0-9]` - Worker nodes

#### 3. 📱 Boot Your Raspberry Pi

Burn the image to your storage device using the provided command:

```bash
sudo dd bs=4M conv=fsync oflag=direct status=progress if=Armbian.img of=/dev/mmcblk0
```

Find your device path using `lsblk` if needed.

Once the media is ready:
1. Insert it into your Raspberry Pi
2. Connect the Pi to your network via Ethernet
3. Power it on

The Pi will automatically execute the appropriate bootstrap script to either initialize the cluster (control plane) or join an existing cluster (secondary control plane or worker).

#### 4. ➕ Add Additional Nodes

##### ⏱️ Time-sensitive warning

> ⚠️ **Important**: The automated node join functionality is time-limited:
> - Control plane certificate keys expire after **2 hours**
> - Worker join tokens expire after **24 hours**
>
> If you're adding nodes within these timeframes, simply repeat steps 2-3 for each additional node.
> For nodes added later, follow the manual process below.

##### Adding nodes after certificate/token expiration

###### For control plane nodes:

1. On an existing control plane node, generate new certificate keys:
   ```bash
   sudo kubeadm init phase upload-certs --upload-certs
   ```
   This command will output a new certificate key.

2. Create a new token:
   ```bash
   sudo kubeadm token create
   ```

3. Get the CA cert hash:
   ```bash
   openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
     openssl rsa -pubin -outform der 2>/dev/null | \
     openssl dgst -sha256 -hex | tr -s ' ' | cut -f2 -d' '
   ```

4. Manually join the new control plane node:
   ```bash
   sudo kubeadm join controlplane:6443 \
     --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash> \
     --control-plane \
     --certificate-key <certificate-key>
   ```

###### For worker nodes:

1. On a control plane node, generate a new join command:
   ```bash
   sudo kubeadm token create --print-join-command
   ```

2. Use that command on the new worker node:
   ```bash
   sudo kubeadm join controlplane:6443 \
     --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```

## 🔧 Additional Configuration

#### 🌐 DHCP reservations

Once you've checked everything is running and your cluster is here to stay, it is a good idea to add a DHCP reservation in your router for the various nodes, in case they reboot.

### 📝 Metrics Server Configuration

For proper metrics-server operation with secure kubelet connections:

1. Add `serverTLSBootstrap: true` to the kubelet's configuration (verify that `rotateCertificates: true` is also set)
2. Restart the kubelet service
3. Approve the generated CSRs to ensure the kubelet has certificates signed by the cluster's CA

This avoids the need to use the insecure `--kubelet-insecure-tls` flag.

For more details, see the [Kubernetes documentation on kubelet serving certificates](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs).

> ⚠️ **Important**: The CSRs for these certificates must be manually approved.
