#!/usr/bin/env python3
"""LiwaLink relay auth service and restaurant registry.

Runs next to frps on the relay server and answers two kinds of questions:

  * frps server-plugin calls (Login, NewProxy): is this restaurant's token
    valid, and is it only publishing its own subdomain over HTTP?
  * Caddy on-demand TLS "ask" calls: should we get a certificate for this host?

The same file is the admin CLI for adding, listing and revoking restaurants.
Standard library only, so it runs on any server with Python 3.8+, Linux or Windows.

    liwalink-auth.py serve  [--listen 127.0.0.1:9000]
    liwalink-auth.py add    <restaurant-id> [--name "Pizza Place"]
    liwalink-auth.py rotate <restaurant-id>
    liwalink-auth.py remove <restaurant-id>
    liwalink-auth.py list
"""

import argparse
import contextlib
import datetime
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None
    import msvcrt

DEFAULT_REGISTRY = "/var/lib/liwalink/restaurants.json"
# Restaurant IDs double as DNS labels: rest-1234 -> rest-1234.<domain>
ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

log = logging.getLogger("liwalink-auth")


def hash_token(token):
    # Tokens are 256-bit random values, so a plain SHA-256 is enough; no need
    # for a slow password hash.
    return hashlib.sha256(token.encode()).hexdigest()


@contextlib.contextmanager
def exclusive_lock(path):
    """Serialize admin commands that edit the registry at the same time."""
    with open(path, "a+") as f:
        if fcntl:
            fcntl.flock(f, fcntl.LOCK_EX)
            yield
            return
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)  # retries for ~10s, then raises
        try:
            yield
        finally:
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)


def replace_file(src, dst):
    # On Windows the rename fails while the server has the file open for a
    # read, which only lasts a moment, so retry briefly.
    for _ in range(50):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if os.name != "nt":
                raise
            time.sleep(0.1)
    os.replace(src, dst)


class Registry:
    """Restaurants stored in a small JSON file.

    The server re-reads the file whenever it changes, so admin commands take
    effect without restarting anything.
    """

    def __init__(self, path):
        self.path = path
        self._mtime = None
        self._restaurants = {}
        self._lock = threading.Lock()

    def restaurants(self):
        try:
            mtime = os.stat(self.path).st_mtime_ns
        except FileNotFoundError:
            return {}
        with self._lock:
            if mtime != self._mtime:
                with open(self.path) as f:
                    self._restaurants = json.load(f).get("restaurants", {})
                self._mtime = mtime
            return self._restaurants

    def check_token(self, restaurant_id, token):
        record = self.restaurants().get(restaurant_id)
        if not record or not token:
            return False
        return hmac.compare_digest(hash_token(token), record["token_sha256"])

    @contextlib.contextmanager
    def edit(self):
        """Lock, load, let the caller modify, then atomically write back."""
        directory = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(directory, exist_ok=True)
        with exclusive_lock(self.path + ".lock"):
            try:
                with open(self.path) as f:
                    data = json.load(f)
            except FileNotFoundError:
                data = {"restaurants": {}}
            yield data["restaurants"]
            fd, tmp = tempfile.mkstemp(dir=directory, prefix=".restaurants-")
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, indent=2, sort_keys=True)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o640)
            replace_file(tmp, self.path)


class Auth:
    def __init__(self, registry, domain):
        self.registry = registry
        self.domain = domain.lower().rstrip(".")

    def check_login(self, content):
        restaurant_id = content.get("user", "")
        token = (content.get("metas") or {}).get("token", "")
        if not self.registry.check_token(restaurant_id, token):
            return "invalid restaurant id or token"
        return None

    def check_new_proxy(self, content):
        user = content.get("user") or {}
        restaurant_id = user.get("user", "")
        if not self.registry.check_token(restaurant_id, (user.get("metas") or {}).get("token", "")):
            return "invalid restaurant id or token"
        # Only HTTP: never open raw TCP/UDP ports (e.g. the database) to the internet.
        if content.get("proxy_type") != "http":
            return "only http proxies are allowed"
        if content.get("custom_domains"):
            return "custom domains are not allowed"
        # A restaurant may only publish its own subdomain, never someone else's.
        if (content.get("subdomain") or "").lower() != restaurant_id:
            return f"restaurant {restaurant_id} may only use subdomain {restaurant_id}"
        return None

    def allow_certificate(self, host):
        host = host.lower().rstrip(".")
        if host == self.domain:
            return True
        suffix = "." + self.domain
        if not host.endswith(suffix):
            return False
        return host[: -len(suffix)] in self.registry.restaurants()


def make_handler(auth):
    class Handler(BaseHTTPRequestHandler):
        server_version = "liwalink-auth"

        def do_POST(self):
            if urlsplit(self.path).path != "/frp/handler":
                return self._reply(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return self._reply(400, {"error": "bad request"})
            op = body.get("op")
            content = body.get("content") or {}
            if op == "Login":
                reason = auth.check_login(content)
                who = content.get("user", "")
                detail = content.get("client_address", "")
            elif op == "NewProxy":
                reason = auth.check_new_proxy(content)
                who = (content.get("user") or {}).get("user", "")
                detail = f"{content.get('proxy_type')} subdomain={content.get('subdomain')}"
            else:
                reason, who, detail = None, "", ""
            if reason:
                log.warning("REJECT %s user=%r %s: %s", op, who, detail, reason)
                return self._reply(200, {"reject": True, "reject_reason": reason})
            log.info("allow %s user=%r %s", op, who, detail)
            self._reply(200, {"reject": False, "unchange": True})

        def do_GET(self):
            url = urlsplit(self.path)
            if url.path == "/caddy/ask":
                host = parse_qs(url.query).get("domain", [""])[0]
                if auth.allow_certificate(host):
                    return self._reply(200, {"allowed": True})
                log.info("deny certificate for %r", host)
                return self._reply(403, {"allowed": False})
            if url.path == "/healthz":
                return self._reply(200, {"ok": True})
            self._reply(404, {"error": "not found"})

        def _reply(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass  # decisions are logged above; skip per-request access logs

    return Handler


def cmd_serve(args, registry):
    if not args.domain:
        sys.exit("serve needs --domain or LIWALINK_DOMAIN")
    host, port = args.listen.rsplit(":", 1)
    server = ThreadingHTTPServer((host, int(port)), make_handler(Auth(registry, args.domain)))
    log.info("listening on %s for *.%s (registry %s)", args.listen, args.domain, registry.path)
    server.serve_forever()


def print_install_help(restaurant_id, token, domain):
    server = domain or "<relay-domain>"
    print(f"  URL:   https://{restaurant_id}.{server}")
    print(f"  Token: {token}")
    print("  (The token is shown only once. Run 'rotate' to issue a new one.)")
    print()
    print("Install the agent on the restaurant machine:")
    print("  Windows (PowerShell as Administrator):")
    print(f"    .\\install-agent.ps1 -RestaurantId {restaurant_id} -Token {token} -Server {server}")
    print("  Linux:")
    print(f"    sudo ./install-agent.sh --id {restaurant_id} --token {token} --server {server}")


def cmd_add(args, registry):
    if not ID_RE.match(args.id):
        sys.exit("restaurant id must be lowercase letters, digits and dashes (it becomes a subdomain)")
    token = secrets.token_urlsafe(32)
    with registry.edit() as restaurants:
        if args.id in restaurants:
            sys.exit(f"{args.id} already exists (use 'rotate' to issue a new token)")
        restaurants[args.id] = {
            "name": args.name or "",
            "token_sha256": hash_token(token),
            "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        }
    print(f"Added {args.id}.")
    print_install_help(args.id, token, args.domain)


def cmd_rotate(args, registry):
    token = secrets.token_urlsafe(32)
    with registry.edit() as restaurants:
        if args.id not in restaurants:
            sys.exit(f"{args.id} not found")
        restaurants[args.id]["token_sha256"] = hash_token(token)
    print(f"New token for {args.id}. The old token stops working on the agent's next reconnect.")
    print_install_help(args.id, token, args.domain)


def cmd_remove(args, registry):
    with registry.edit() as restaurants:
        if restaurants.pop(args.id, None) is None:
            sys.exit(f"{args.id} not found")
    print(f"Removed {args.id}. It can no longer log in; an agent that is already")
    print("connected stays up until it reconnects (restart liwalink-relay to cut it off now).")


def cmd_list(args, registry):
    restaurants = registry.restaurants()
    if not restaurants:
        print("No restaurants yet. Add one with: add <restaurant-id>")
        return
    for restaurant_id in sorted(restaurants):
        record = restaurants[restaurant_id]
        print(f"{restaurant_id:<24} {record.get('created', ''):<26} {record.get('name', '')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", default=os.environ.get("LIWALINK_REGISTRY", DEFAULT_REGISTRY))
    parser.add_argument("--domain", default=os.environ.get("LIWALINK_DOMAIN", ""),
                        help="relay domain, e.g. link.example.com")
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="run the frps plugin + Caddy ask endpoint")
    serve.add_argument("--listen", default="127.0.0.1:9000")
    serve.set_defaults(func=cmd_serve)

    add = sub.add_parser("add", help="register a restaurant and print its token")
    add.add_argument("id")
    add.add_argument("--name", help="display name, for your own reference")
    add.set_defaults(func=cmd_add)

    rotate = sub.add_parser("rotate", help="issue a new token for a restaurant")
    rotate.add_argument("id")
    rotate.set_defaults(func=cmd_rotate)

    remove = sub.add_parser("remove", help="revoke a restaurant")
    remove.add_argument("id")
    remove.set_defaults(func=cmd_remove)

    sub.add_parser("list", help="list restaurants").set_defaults(func=cmd_list)

    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args.func(args, Registry(args.registry))


if __name__ == "__main__":
    main()
