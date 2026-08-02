# Aura Cloud - Docker Compose deployment

Runs Aura Cloud and the OpenWiFi microservices on a single host.

## What gets deployed

| Service | Port | Purpose |
| --- | --- | --- |
| aura-cloud | 9090 | Aura management interface and API |
| owgw | 15002 | Access points connect here |
| owgw | 16002 | Gateway REST API |
| owsec | 16001 | Authentication for the OpenWiFi services |
| owfms | 16004 | Firmware management |
| owprov | 16005 | Provisioning |
| owanalytics | 16009 | Analytics |
| owsub | 16006 | Subscriber services |
| owgw-ui | 443 | OpenWiFi web interface |
| owprov-ui | 8443 | Provisioning web interface |
| postgresql | - | Database, not published outside the host |
| kafka | - | Message bus, not published outside the host |

## Requirements

Docker Engine with the Compose v2 plugin:

    docker compose version

If this fails, install the plugin. The older `docker-compose` command cannot
read this compose file: it has no top-level `version:` key, so v1 falls back
to the legacy schema and reports "Unsupported config option for services".

    sudo apt-get install docker-compose-v2

Your user needs access to the Docker socket:

    sudo usermod -aG docker $USER

Log out and back in for that to take effect.

## Choosing the Aura release

The Aura binary is downloaded when the image is built, so nothing needs
to be fetched by hand. Set the release in `.env`:

    AURA_TAG=v1.35

The builds are published at:

    https://pub-7cae4dbc3c7b408cb8d423016465e3b9.r2.dev/releases/<tag>/aura-cloud
    https://pub-7cae4dbc3c7b408cb8d423016465e3b9.r2.dev/releases/<tag>/aura-cloud-arm64

The host needs to reach that address at build time, but not afterwards.
The right build for the architecture is selected automatically, so the
same configuration works on x86_64 and on arm64 including Raspberry Pi.

To move to a later release, change `AURA_TAG` and run
`./update_aura.sh`.

## Installing

    ./install.sh

The installer:

1. Checks Compose v2, the Docker socket, free ports, and that the Postgres
   image provides pgvector.
2. Asks for an administrator email and password, and the hostname that
   browsers and access points will use.
3. Generates the database password and the token signing secret.
4. Writes `aura-cloud.env` and sets the hostname in the OpenWiFi service
   configuration.
5. Starts the stack and waits for it to come up.
6. Runs `bootstrap_owsec.sh` to set the OpenWiFi administrator password and
   create the account Aura uses to reach the OpenWiFi services.

It prints the addresses and the login when it finishes.

### The hostname matters

Access points fetch firmware and connect for remote terminal using the
hostname supplied during installation, so it must resolve from the access
point network, not only from your browser. A static address or a DHCP
reservation is worth setting up first.

### After installing

The installer prints the addresses and the login. See
[Web interfaces](#web-interfaces) below: the certificate warning has to be
accepted for port 16001 before the OpenWiFi interface will let anyone sign
in.

## Web interfaces

Replace `<hostname>` with the value given during installation.

| Interface | Address | Sign in with |
| --- | --- | --- |
| Aura | `http://<hostname>:9090` | your administrator email |
| OpenWiFi | `https://<hostname>` | `tip@ucentral.com` |
| Provisioning | `https://<hostname>:8443` | `tip@ucentral.com` |

Aura is the day to day interface. The OpenWiFi interfaces are the upstream
tools and are mainly useful for looking at gateway state directly.

### Certificate warnings

The certificates shipped here are self-signed, so browsers show a warning
on first visit. Choose "Advanced" and continue.

The warning has to be accepted separately for each port, because browsers
treat a different port as a different site. The OpenWiFi interface calls
the authentication service on port 16001, and until that certificate is
accepted the call is blocked silently and every login fails with "Invalid
Credentials", the same message shown for a wrong password.

Visit this once, before signing in:

    https://<hostname>:16001/api/v1/systemEndpoints

A page reading `"Security service is unreachable"` or an authentication
error is the expected result. It means the certificate is now accepted.

If the Aura interface loads but shows no data, the same thing has happened
for the gateway and provisioning APIs. Accept those too:

    https://<hostname>:16002/api/v1/system?command=info
    https://<hostname>:16005/api/v1/system?command=info

### If the address does not resolve

The installer configures the services with the hostname you supplied. If
your browser cannot resolve it, either add a DNS record pointing at the
host, or add a line to your machine's hosts file:

    <ip-address>  <hostname>

On Linux and macOS that is `/etc/hosts`; on Windows,
`C:\Windows\System32\drivers\etc\hosts`.

Note that `.local` names are reserved for multicast DNS and are not
resolved through a normal DNS server on Linux and macOS. Use a different
suffix.

## Day to day

    ./start_aura.sh          # start
    ./stop_aura.sh           # stop, keeping all data
    ./status.sh              # what is running, and common problems
    ./update_aura.sh         # move to the release named by AURA_TAG

    docker compose logs -f aura-cloud
    docker compose logs -f owgw

## Accounts

Installation creates three separate logins. They are not interchangeable.

| Account | Where | Set by |
| --- | --- | --- |
| Your administrator email | Aura, port 9090 | you, during install |
| `tip@ucentral.com` | OpenWiFi UI, port 443 | you, during install |
| `aura-service@ucentral.com` | not for signing in | generated |

The third is a machine account Aura uses to call the OpenWiFi services.
Changing or deleting it stops Aura managing devices. It is stored in
`aura-cloud.env`.

If the OpenWiFi credentials are ever lost or need to change:

    ./reset.sh --owsec-only
    ./bootstrap_owsec.sh

That reissues them without touching devices or history.

## Firmware

Nearhop publishes access point firmware built and tested against each
Aura release. The manifests in `firmware/` list the images for every
supported model, with checksums and build provenance.

To make a release available:

1. Sign in to Aura as a superadmin.
2. Go to Firmware, then Releases.
3. Choose "Import from manifest" and upload the file from `firmware/`.
4. Review the preview and confirm.

The release is imported as a draft. Publish it, then push to access
points from the same section.

Access points fetch the image themselves from the URL in the manifest,
so they need outbound HTTPS access to it. Deployments without internet
access need the images hosted locally and the manifest URLs changed to
match before importing.

## Removing

    ./reset.sh                 # everything
    ./reset.sh --keep-config   # data only, keeps aura-cloud.env

A full reset deletes all devices, users and history. It also clears the
per-service state files under `*_data/persist/`. Those live on the host
rather than in a volume, so `docker compose down -v` alone does not remove
them, and a leftover `registry.json` stops the authentication service
recreating its administrator account. The symptom is a stack that starts
cleanly and rejects every login.

## Configuration files

| File | Contents |
| --- | --- |
| `aura-cloud.env` | Aura configuration and credentials. Generated. Not in git. |
| `aura-cloud.env.example` | Documents every setting. |
| `.env` | Image tags and the internal service hostnames. |
| `ow*.env` | OpenWiFi service configuration. |
| `postgresql.env` | Database names and credentials. |
| `certs/` | TLS certificates for the gateway and the REST APIs. |

`SYSTEM_URI_PRIVATE` in the service env files refers to the Docker network
aliases and is resolved only between containers. Changing it breaks every
call between services. `SYSTEM_URI_PUBLIC` is the one browsers follow, and
the installer sets it from the hostname you supply.

## Access point certificates

Access points and the gateway authenticate each other with client
certificates. The certificates in `certs/` decide which access points are
accepted:

- `websocket-cert.pem`, `websocket-key.pem` - the gateway's own identity,
  which the access point verifies
- `clientcas.pem` - the certificate authorities whose access points the
  gateway will accept
- `issuer.pem` - sent with the gateway certificate so the access point can
  build a chain

The shipped certificates match the ones access points carry from the
factory, so a standard deployment needs no changes here.

## Troubleshooting

Start with:

    ./status.sh

**A port is already in use.** `install.sh` reports which one. Change the
mapping in `docker-compose.yml` or stop whatever holds it:

    sudo ss -tlnp '( sport = :443 )'

**"Invalid Credentials" in the OpenWiFi interface.** That message covers
every failure, including ones that are not about the password. Test the
service directly:

    curl -k -X POST https://127.0.0.1:16001/api/v1/oauth2 \
      -H 'Content-Type: application/json' \
      -d '{"userId":"tip@ucentral.com","password":"<password>"}'

A token means the credentials are correct and the browser cannot reach the
service, usually because the certificate has not been accepted for port
16001.

**aura-cloud restarts repeatedly.** It retries rather than exiting, so a
configuration problem looks like a slow start:

    docker compose logs --tail=30 aura-cloud

**Access points do not appear.** Check the gateway is listening and
reachable from the access point network:

    ss -tln | grep 15002
    docker compose logs owgw | grep -i alert

**Nothing works after a reinstall.** Some state lives on the host rather
than in the volumes. Use `./reset.sh` rather than `docker compose down -v`.
