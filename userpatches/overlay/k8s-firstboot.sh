# k8s install script
#!/bin/bash

# just to be sure everything else is set up
sleep 5

# create token for both controlplane and node
TOKEN=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 6).$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16)

# run kubeadm init for controlplane or kubeadm join for nodes
# based on the hostname
HOST_TYPE="$(cat /etc/hostname)"
if [[ ${HOST_TYPE%%[0-9]*} = controlplane ]]; then
    kubeadm init --control-plane-endpoint=cluster-endpoint \
	    --token=$TOKEN \
	    --pod-network-cidr 172.16.0.0/16 \
	    --service-cidr 10.96.0.0/12 \
	    --config /root/kubeadm-config.yaml
else
    kubeadm join --control-plane-endpoint=cluster-endpoint \
	    --token=$TOKEN \
	    --discovery-token-unsafe-skip-ca-verification
fi
