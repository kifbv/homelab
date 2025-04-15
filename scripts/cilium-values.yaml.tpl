k8sServiceHost: $HOST_IP
k8sServicePort: 6443

kubeProxyReplacement: true

hubble:
  relay:
    enabled: true
  ui:
    enabled: true

#hostFirewall:
#  enabled: true

l2announcements:
  enabled: true

externalIPs:
  enabled: true

gatewayAPI:
  enabled: true

debug:
  enabled: true
  verbose: flow

#authentication:
#  mutual:
#    spire:
#      enabled: true
#      install:
#        enabled: true
#        server:
#          dataStorage:
#            enabled: false
