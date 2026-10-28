# Stand-in for ghcr.io/etqan-agency/chatbot/dashboard. Built and tagged under
# that name by scripts/e2e.sh so the REAL compose file runs unmodified.
FROM nginx:alpine

ARG RELEASE=dev
ENV RELEASE=${RELEASE}

COPY default.conf /etc/nginx/conf.d/default.conf

# The release marker has to reach nginx as a config value, and nginx does not
# read the process environment from within a vhost. `map` with a default is the
# standard way in; templating the value at build time via `envsubst` would work
# too but leaves no readable artefact in the running container.
RUN printf 'map $host $e2e_release { default "%s"; }\n' "${RELEASE}" \
      > /etc/nginx/conf.d/00-release.conf \
    && printf 'dashboard %s\n' "${RELEASE}" > /usr/share/nginx/html/index.html

# The real dashboard image declares a HEALTHCHECK (chabot_dev_dash/
# Dockerfile), and wait_containers_healthy is only a real gate for services
# whose image has one -- without it container_health reports "none:running"
# the instant the container starts and the roll proceeds against a container
# that may not be serving yet. Compressed intervals, same reasoning as the api
# stand-in.
HEALTHCHECK --interval=2s --timeout=3s --start-period=2s --retries=3 \
    CMD wget -q --spider http://127.0.0.1/healthz || exit 1
