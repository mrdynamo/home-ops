---
# topf generates this document for every node with /dev/sda; installer.image comes from
# factory + schematicId + talosVersion in topf.yaml.
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: disk.dev_path == {{ .Node.Data.installDisk | quote }}
