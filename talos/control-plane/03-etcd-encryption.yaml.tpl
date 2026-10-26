---
# The cluster's etcd data was written with the secretbox key named "key2", and the name is
# stored with every encrypted secret. The identity provider keeps any secret written before
# encryption was enabled readable. The secret is secrets.secretboxencryptionsecret from the
# secrets bundle.
apiVersion: v1alpha1
kind: KubeEtcdEncryptionConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeEtcdEncryptionConfig
config:
  resources:
    - providers:
        - secretbox:
            keys:
              - name: key2
                secret: {{ .Data.etcdSecretboxSecret | quote }}
        - identity: {}
      resources:
        - secrets
