kubeProxyReplacement: true

k8sServiceHost: $HOST_IP
k8sServicePort: 6443

hubble:
  relay:
    enabled: true
  ui:
    enabled: true

gatewayAPI:
  enabled: true
  hostNetwork:
    enabled: true

authentication:
  mutual:
    spire:
      enabled: true
      install:
        enabled: true
        server:
          dataStorage:
            enabled: false
