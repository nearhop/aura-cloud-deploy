# aura-cloud-deploy

Deployment manifests for Aura Cloud, the Nearhop WLAN controller platform.

Aura runs alongside the [OpenWiFi](https://openwifi.tip.build/) microservices:
the OpenWiFi gateway terminates the connection from the access points, and
Aura provides the management interface, health scoring, RRM and analytics on
top of it. This repository deploys the whole stack as a single set of
containers.

It is a fork of
[wlan-cloud-ucentral-deploy](https://github.com/Telecominfraproject/wlan-cloud-ucentral-deploy),
reduced to the Docker Compose deployment and extended with the Aura service
and its setup scripts.

Everything lives in [docker-compose](docker-compose). See
[docker-compose/README.md](docker-compose/README.md) for the details.

## Requirements

- Docker Engine with the Compose v2 plugin (`docker compose`, not
  `docker-compose`)
- 8 GB RAM and 20 GB disk for a typical single-site deployment
- A hostname or static address that both browsers and access points can
  reach

## Quick start

    git clone https://github.com/nearhop/aura-cloud-deploy.git
    cd aura-cloud-deploy/docker-compose
    ./install.sh

The Aura binary is downloaded when the image is built. The release comes
from `AURA_TAG` in `.env`.

The installer checks the host, generates the credentials, configures the
services and starts them. It prints the addresses and the administrator
login when it finishes.

## Scripts

All are run from the `docker-compose` directory.

| Script | Purpose |
| --- | --- |
| `install.sh` | First-run setup. Run once. |
| `start_aura.sh` | Start the stack. |
| `stop_aura.sh` | Stop the stack. Data is kept. |
| `status.sh` | Show what is running and check for common problems. |
| `update_aura.sh` | Move to the release named by `AURA_TAG`. |
| `bootstrap_owsec.sh` | Reissue the OpenWiFi credentials Aura uses. |
| `reset.sh` | Remove data and configuration. |

## Kubernetes

The upstream project also publishes a Helm chart. It is not carried here:
Aura's on-premise deployment targets a single host, where Compose is simpler
to install, operate and support. The chart in the upstream repository can be
used as a starting point if a cluster deployment is ever needed.
