---
# Talos sends these from the host network, where *.svc.cluster.local does not resolve
# (the host resolver is 1.1.1.1), so they go to the fixed LoadBalancer IP of
# kubernetes/apps/observability/fluent-bit/app/service.yaml.
machine:
  logging:
    destinations:
      - endpoint: "udp://192.168.30.131:10001/"
        format: "json_lines"
        extraTags:
          node: {{ .Node.Host }}
---
# Kernel log shipping. Supersedes the `talos.logging.kernel=` kernel argument in the
# schematics, which points at a cluster DNS name and so never delivers anything; drop that
# argument the next time the schematics change. KmsgLogConfig has no extraTags before
# Talos v1.15, so fluent-bit derives the node from the sender address instead.
apiVersion: v1alpha1
kind: KmsgLogConfig
name: fluent-bit
url: udp://192.168.30.131:10002/
