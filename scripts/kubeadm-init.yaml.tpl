---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/crio/crio.sock"
  kubeletExtraArgs:
    container-runtime: "remote"
    container-runtime-endpoint: "unix:///var/run/crio/crio.sock"
bootstrapTokens:
  - token: "${TOKEN}"
    description: "kubeadm bootstrap token"
    ttl: "24h"
certificateKey: "${CERT_KEY}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  serviceSubnet: "10.244.0.0/20"
  podSubnet: "10.244.64.0/18"
controlPlaneEndpoint: "${HOST_IP}:6443"
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
rotateCertificates: true