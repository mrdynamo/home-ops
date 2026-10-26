---
machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:{{ .KubernetesVersion }}
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true
    extraConfig:
      featureGates:
        ResourceHealthStatus: true
        DRAExtendedResource: true
      serializeImagePulls: false
    nodeIP:
      validSubnets:
        - 192.168.30.0/24
