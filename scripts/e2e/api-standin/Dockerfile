# Stand-in for ghcr.io/etqan-agency/chatbot/api, built and tagged under that
# name by scripts/e2e.sh so the REAL docker-compose.production.yml runs
# unmodified against it. See scripts/e2e/README.md for what that buys.
FROM python:3.13-alpine

ARG RELEASE=dev
ENV RELEASE=${RELEASE}
ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY server.py manage.py /app/
COPY celery /usr/local/bin/celery
RUN chmod +x /usr/local/bin/celery /app/manage.py \
    && mkdir -p /app/staticfiles /app/media

# Mirrors the real image's probe (chabot_dev_api/Dockerfile) in shape: same route,
# same failure semantics. The intervals are compressed because a rehearsal that
# waits 60s per container for a start_period it does not need is a rehearsal
# nobody runs. wait_containers_healthy reads the verdict, not the timings.
HEALTHCHECK --interval=2s --timeout=3s --start-period=2s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8000/health/ || exit 1

EXPOSE 8000
CMD ["python", "/app/server.py"]
