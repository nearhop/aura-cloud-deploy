# Aura Cloud - runtime image
#
# The binary is downloaded at build time from the published releases,
# so nothing needs to be fetched by hand and no binary is kept in the
# repository.
#
# The version comes from AURA_TAG in the compose env file. To move to a
# different release, change it there and run ./update_aura.sh.
#
# TARGETARCH is set by BuildKit, so the same Dockerfile produces amd64
# and arm64 images without edits.
#
# The published builds are statically linked. That matters here: Alpine
# uses musl, and a glibc-linked binary will not start at all.

FROM alpine:3.20

ARG TARGETARCH
ARG AURA_TAG
ARG AURA_BASE_URL=https://pub-7cae4dbc3c7b408cb8d423016465e3b9.r2.dev/releases

# ca-certificates: outbound TLS to owgw, owsec and any AI provider.
# tzdata: a static Go binary carries no timezone database and silently
#         falls back to UTC without it.
RUN apk add --no-cache ca-certificates tzdata curl \
    && adduser -D -u 10001 aura

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) asset="aura-cloud" ;; \
        arm64) asset="aura-cloud-arm64" ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="${AURA_BASE_URL}/${AURA_TAG}/${asset}"; \
    echo "fetching ${url}"; \
    curl -fSL --retry 3 --retry-delay 2 "${url}" -o /usr/local/bin/aura-cloud; \
    chmod 0755 /usr/local/bin/aura-cloud; \
    /usr/local/bin/aura-cloud --version 2>/dev/null || true

# curl is only needed for the download above.
RUN apk del curl

USER aura
EXPOSE 9090

ENTRYPOINT ["/usr/local/bin/aura-cloud"]
