# Rendered by deploy.sh via envsubst (MODEL_API_FQDN).
# Do not commit the generated traefik/dynamic/model-api.yml.
#
# Upstream is the host bridge gateway address where docker model gateway binds.
# Authorization is enforced by the gateway master_key, not Traefik.

http:
  routers:
    model-api:
      rule: "Host(`${MODEL_API_FQDN}`)"
      entryPoints:
        - websecure
      service: model-gateway
      tls:
        certResolver: letsencrypt

  services:
    model-gateway:
      loadBalancer:
        servers:
          - url: "http://172.30.50.1:4000"
