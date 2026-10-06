"""Shared outbound connections and managed identity credentials for calls to Azure.

Each Azure call used to open its own TLS connection, and most fetched a new managed identity
token as well. On AKS every new outbound connection holds one of the node's load balancer
SNAT ports for minutes, so a report build or a busy processor run could use all of them and
later calls failed to connect. Calls now share one HTTP connection pool and one credential
per event loop, and blob clients share one credential and connection pool per process.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from dataclasses import dataclass, field

import httpx
from azure.identity import ManagedIdentityCredential
from azure.identity.aio import ManagedIdentityCredential as AsyncManagedIdentityCredential
from azure.storage.blob import BlobServiceClient

ARM_BASE = "https://management.azure.com"
ARM_SCOPE = f"{ARM_BASE}/.default"
# Idle connections are closed after 30 seconds, well inside the load balancer's idle timeout,
# so the pool never reuses a connection the load balancer has already dropped.
_LIMITS = httpx.Limits(max_connections=64, max_keepalive_connections=32, keepalive_expiry=30.0)


@dataclass
class _LoopConnections:
    loop: asyncio.AbstractEventLoop
    http: httpx.AsyncClient
    credentials: dict[str, AsyncManagedIdentityCredential] = field(default_factory=dict)


_loop_connections: _LoopConnections | None = None
_lock = threading.Lock()
_credentials: dict[str, ManagedIdentityCredential] = {}
_blob_services: dict[tuple, BlobServiceClient] = {}


def _connections() -> _LoopConnections:
    global _loop_connections
    loop = asyncio.get_running_loop()
    current = _loop_connections
    if current is None or current.loop is not loop or current.http.is_closed:
        # A process runs one event loop; another loop (asyncio.run in a test) gets a fresh pool.
        client = httpx.AsyncClient(timeout=30.0, limits=_LIMITS, follow_redirects=False)
        current = _loop_connections = _LoopConnections(loop, client)
    return current


def http_client() -> httpx.AsyncClient:
    """The event loop's shared connection pool. Use absolute URLs and pass a timeout per request."""
    return _connections().http


async def arm_token(client_id: str) -> str:
    """An Azure Resource Manager token for the managed identity; its credential caches and renews it."""
    credentials = _connections().credentials
    credential = credentials.get(client_id)
    if credential is None:
        credential = credentials[client_id] = AsyncManagedIdentityCredential(client_id=client_id)
    return (await credential.get_token(ARM_SCOPE)).token


def credential(client_id: str) -> ManagedIdentityCredential:
    """The process-wide synchronous credential for the managed identity."""
    with _lock:
        shared = _credentials.get(client_id)
        if shared is None:
            shared = _credentials[client_id] = ManagedIdentityCredential(client_id=client_id)
        return shared


def blob_service(account_url: str, client_id: str, **options) -> BlobServiceClient:
    """One blob client per account, identity and option set. Azure SDK clients are thread-safe."""
    key = (account_url, client_id, tuple(sorted(options.items())))
    shared = credential(client_id)
    with _lock:
        service = _blob_services.get(key)
        if service is None:
            service = _blob_services[key] = BlobServiceClient(account_url, credential=shared, **options)
        return service


async def aclose() -> None:
    """Closes this event loop's pool and credentials. Call once when the process shuts down."""
    global _loop_connections
    current, _loop_connections = _loop_connections, None
    if current is None or current.loop is not asyncio.get_running_loop():
        return
    try:
        for item in current.credentials.values():
            await item.close()
    finally:
        await current.http.aclose()


def quiet_sdk_http_logging() -> None:
    """The Azure SDKs log every request and response at INFO, which buries the application's own logs."""
    logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)


def reset() -> None:
    """Forgets every shared client without closing it, so each test starts with fresh ones."""
    global _loop_connections
    with _lock:
        _loop_connections = None
        _credentials.clear()
        _blob_services.clear()
