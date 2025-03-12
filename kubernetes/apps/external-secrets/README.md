
# Onepassword Connect

## Deployment
```yaml
services:
  onepassword-connect-api:
    container_name: onepassword-connect-api
    image: 1password/connect-api:latest
    environment:
      OP_HTTP_PORT: 7070
      OP_SESSION: TWFkZSB5YSBsb29rIQ==
      XDG_DATA_HOME: /config
    network_mode: host
    restart: unless-stopped
    volumes:
      - "data:/config"
  onepassword-connect-sync:
    container_name: onepassword-connect-sync
    image: 1password/connect-sync:latest
    environment:
      OP_HTTP_PORT: 7071
      OP_SESSION: TWFkZSB5YSBsb29rIQ==
      XDG_DATA_HOME: /config
    network_mode: host
    restart: unless-stopped
    volumes:
      - "data:/config"

volumes:
  data:
    driver: local
    driver_opts:
      device: tmpfs
      o: uid=999,gid=999
      type: tmpfs
```