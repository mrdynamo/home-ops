---
# topf's `host` is only a label, so without this every node would be renamed to
# talos-xxx-xxx.
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
