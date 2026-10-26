---
## OIDC (Authentik) - https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration
apiVersion: v1alpha1
kind: KubeAuthenticationConfig
configuration:
  anonymous:
    enabled: true
    conditions:
      - path: /livez
      - path: /readyz
      - path: /healthz
  jwt:
    - issuer:
        url: https://auth.{{ .Data.secretDomain }}/application/o/kubernetes/
        audiences:
          - q1jBQ6YhLPzCzTHzbY5mUUeIVgosmrIYZMhL4JYx
      claimMappings:
        username:
          claim: preferred_username
          prefix: "oidc:"
        groups:
          claim: groups
          prefix: "oidc:"
