"""Stand-in for the chatbot API, for the deploy rehearsal in scripts/e2e.sh.

This is NOT a mock of the application. It implements the contract that
docker-compose.production.yml, traefik.yml and scripts/lib/services.sh require
of whatever image is deployed as `web`, and nothing else:

  * listens on :8000
  * GET /health/ returns 200, or 503 once DRAIN_FILE exists -- the drain gate
    that retire_container depends on (services.sh marks `web` drainable=true,
    and a service marked drainable whose health route never fails turns the
    settle window into a sleep and the stop back into an abrupt one)
  * every response carries X-E2E-Release, so the rehearsal can prove WHICH
    generation served a given request rather than inferring it from timing

Baking the release into the image (via the RELEASE build arg) rather than
reading it from .env is deliberate: .env is identical for both generations
during a roll, so an env-sourced value could not distinguish them -- which is
the one thing this server exists to do.
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RELEASE = os.environ.get("RELEASE", "unknown")
DRAIN_FILE = os.environ.get("DRAIN_FILE", "/tmp/drain")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-E2E-Release", RELEASE)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        # `== "/health"`, and deliberately NOT `in ("/health", "")`. The
        # earlier form matched "" as well, and "/".rstrip("/") IS "" -- so the
        # ROOT path silently became the drain-aware health route. Every
        # availability probe then 503'd for the whole drain window, and the
        # rehearsal reported ~2s of downtime per roll that the rollout had not
        # actually caused. The two routes must stay distinct: /health/ is the
        # signal to Traefik that this replica should leave the pool, while /
        # is real traffic that a draining replica MUST keep serving until it
        # is stopped. That difference is the entire point of a drain.
        if self.path.rstrip("/") == "/health":
            if os.path.exists(DRAIN_FILE):
                # 503, not a connection refusal: Traefik must observe a FAILED
                # probe and remove this backend while the process is still
                # accepting and completing in-flight requests. That is the
                # whole difference between a drain and a stop.
                self._reply(503, "draining\n")
            else:
                self._reply(200, "ok\n")
        else:
            self._reply(200, f"api {RELEASE} {self.path}\n")

    # The default logs every request to stderr, which buries the rehearsal's
    # own output under the zero-downtime probe's traffic.
    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"api stand-in {RELEASE} listening on :8000", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
