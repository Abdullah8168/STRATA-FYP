"""Shared network-namespace topology for the firewall integration tests.

The root namespace plays the Pi. Other namespaces play the guest phone
(``strata_host.firewall.netns.guest_namespace``), the internet, a device on
the host's home LAN, or a WireGuard exit. Each "remote" namespace runs a tiny
HTTP server whose ``/who`` answer says which one was reached, so a test can
assert *where* a guest's packet ended up, not just that something answered.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from strata_host.firewall.netns import in_ns

TARGET = "198.51.100.7"  # a public-looking address "on the internet"
PORT = 9000

# `python -m http.server` reverse-resolves its bind address before it starts
# listening; inside these namespaces DNS has nowhere to go, so that stalls
# for ~10 s. This server skips the lookup. argv: bind_ip docroot
_SERVER_CODE = f"""
import functools, http.server, socketserver, sys
class Server(http.server.HTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "test", self.server_address[1]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[2])
Server((sys.argv[1], {PORT}), handler).serve_forever()
"""


def sh(*cmd: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), capture_output=True, text=True, check=check)


def make_link(ns: str, host_if: str, peer_if: str, host_ip: str, peer_ip: str) -> None:
    """veth between the root namespace (host_ip/24) and ``ns`` (peer_ip/24);
    ``ns`` gets a default route back through the root namespace."""
    sh("ip", "link", "add", host_if, "type", "veth", "peer", "name", peer_if)
    sh("ip", "link", "set", peer_if, "netns", ns)
    sh("ip", "addr", "add", f"{host_ip}/24", "dev", host_if)
    sh("ip", "link", "set", host_if, "up")
    sh("ip", "netns", "exec", ns, "ip", "addr", "add", f"{peer_ip}/24", "dev", peer_if)
    sh("ip", "netns", "exec", ns, "ip", "link", "set", peer_if, "up")
    sh("ip", "netns", "exec", ns, "ip", "route", "replace", "default", "via", host_ip)


def fetch_code(ip: str = TARGET, path: str = "/who", source: str | None = None,
               size_only: bool = False) -> str:
    src = f", source_address=({source!r}, 0)" if source else ""
    out = "len(body)" if size_only else "body.decode()"
    return (
        "import http.client as h\n"
        f"c = h.HTTPConnection({ip!r}, {PORT}, timeout=3{src})\n"
        "try:\n"
        f"    c.request('GET', {path!r}); body = c.getresponse().read(); print({out})\n"
        "except OSError as e:\n"
        "    print('FAIL', type(e).__name__)\n"
    )


def fetch(ns: str | None, ip: str = TARGET, path: str = "/who", *,
          source: str | None = None, size_only: bool = False) -> str:
    """GET http://ip:PORT/path from namespace ``ns`` (None = the Pi itself).
    Returns the body, the byte count with ``size_only``, or ``FAIL <error>``."""
    code = fetch_code(ip, path, source, size_only)
    if ns is None:
        return sh(sys.executable, "-c", code, check=False).stdout.strip()
    return in_ns(ns, [sys.executable, "-c", code]).stdout.strip()


@contextmanager
def http_server(ns: str, bind_ip: str, label: str,
                files: dict[str, bytes] | None = None) -> Iterator[None]:
    """Serve ``/who`` -> label (plus ``files``) from ``ns`` on bind_ip:PORT."""
    docroot = tempfile.mkdtemp(prefix=f"strata-{label.lower()}-")
    Path(docroot, "who").write_text(label)
    for name, data in (files or {}).items():
        Path(docroot, name).write_bytes(data)
    server = subprocess.Popen(
        ["ip", "netns", "exec", ns, sys.executable, "-c", _SERVER_CODE, bind_ip, docroot],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(50):
            if fetch(ns, bind_ip) == label:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"test HTTP server {label} in {ns} never answered")
        yield
    finally:
        server.terminate()
        server.wait(timeout=5)


@contextmanager
def remote_namespace(ns: str, host_if: str, peer_if: str, subnet: str, label: str, *,
                     serve_ip: str | None = TARGET,
                     files: dict[str, bytes] | None = None) -> Iterator[None]:
    """A namespace linked to the Pi over ``subnet``.0/24 (Pi = .1, ns = .2).

    With ``serve_ip`` (default TARGET) it owns that address on lo and serves
    it; with None it serves on its link address ``subnet``.2.
    """
    sh("ip", "netns", "del", ns, check=False)
    sh("ip", "link", "del", host_if, check=False)
    sh("ip", "netns", "add", ns)
    sh("ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up")
    if serve_ip is not None:
        sh("ip", "netns", "exec", ns, "ip", "addr", "add", f"{serve_ip}/32", "dev", "lo")
    make_link(ns, host_if, peer_if, f"{subnet}.1", f"{subnet}.2")
    try:
        with http_server(ns, serve_ip or f"{subnet}.2", label, files):
            yield
    finally:
        sh("ip", "netns", "del", ns, check=False)
        sh("ip", "link", "del", host_if, check=False)
