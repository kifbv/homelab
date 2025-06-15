apiVersion: kubeadm.k8s.io/v1beta4
bootstrapTokens:
- description: kubeadm bootstrap token
  groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: "$TOKEN"
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
certificateKey: "$CERT_KEY"
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$HOST_IP"
  bindPort: 6443
nodeRegistration:
  imagePullPolicy: IfNotPresent
  imagePullSerial: true
  name: controlplane
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/control-plane
timeouts:
  controlPlaneComponentHealthCheck: 4m0s
  discovery: 5m0s
  etcdAPICall: 2m0s
  kubeletHealthCheck: 4m0s
  kubernetesAPICall: 1m0s
  tlsBootstrap: 5m0s
  upgradeManifests: 5m0s
---
apiServer: {}
apiVersion: kubeadm.k8s.io/v1beta4
caCertificateValidityPeriod: 87600h0m0s
certificateValidityPeriod: 8760h0m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controlPlaneEndpoint: $HOST_IP:6443
controllerManager: {}
dns: {}
encryptionAlgorithm: RSA-2048
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.k8s.io
kind: ClusterConfiguration
networking:
  dnsDomain: cluster.local
  podSubnet: $POD_SUBNET
  serviceSubnet: $SERVICE_SUBNET
proxy: {}
scheduler: {}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
rotateCertificates: true
