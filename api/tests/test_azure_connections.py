import asyncio
import logging

import httpx
from fastapi.testclient import TestClient

from services import azure_connections


def test_each_event_loop_reuses_one_pool_until_shutdown():
    async def first_loop():
        pool = azure_connections.http_client()
        assert azure_connections.http_client() is pool
        await azure_connections.aclose()
        assert pool.is_closed
        return pool

    closed = asyncio.run(first_loop())

    async def next_loop():
        try:
            return azure_connections.http_client()
        finally:
            await azure_connections.aclose()

    assert asyncio.run(next_loop()) is not closed


def test_pool_never_follows_redirects_and_drops_idle_connections_before_the_load_balancer(monkeypatch):
    options = []
    actual = httpx.AsyncClient

    def client(**kwargs):
        options.append(kwargs)
        return actual(**kwargs)

    async def create_then_shut_down():
        azure_connections.http_client()
        await azure_connections.aclose()

    monkeypatch.setattr(azure_connections.httpx, "AsyncClient", client)
    asyncio.run(create_then_shut_down())
    assert len(options) == 1 and options[0]["follow_redirects"] is False
    # The load balancer drops idle flows after 4 minutes; reusing one of those would fail the request.
    assert options[0]["limits"].keepalive_expiry <= 60


def test_arm_tokens_come_from_one_credential_per_identity(monkeypatch):
    created, scopes = [], []

    class Credential:
        def __init__(self, *, client_id):
            created.append(client_id)

        async def get_token(self, scope):
            scopes.append(scope)
            return type("Token", (), {"token": f"token-{len(scopes)}"})()

        async def close(self):
            created.append("closed")

    async def tokens():
        try:
            return [await azure_connections.arm_token("id-1"), await azure_connections.arm_token("id-1"),
                    await azure_connections.arm_token("id-2")]
        finally:
            await azure_connections.aclose()

    monkeypatch.setattr(azure_connections, "AsyncManagedIdentityCredential", Credential)
    assert asyncio.run(tokens()) == ["token-1", "token-2", "token-3"]
    assert created == ["id-1", "id-2", "closed", "closed"]
    assert scopes == ["https://management.azure.com/.default"] * 3


def test_blob_clients_are_shared_per_account_identity_and_options(monkeypatch):
    class Service:
        def __init__(self, url, *, credential, **options):
            self.url, self.credential, self.options = url, credential, options

    monkeypatch.setattr(azure_connections, "ManagedIdentityCredential", lambda *, client_id: object())
    monkeypatch.setattr(azure_connections, "BlobServiceClient", Service)
    url = "https://teststore.blob.core.windows.net"
    first = azure_connections.blob_service(url, "id-1", retry_total=0, read_timeout=10)
    assert azure_connections.blob_service(url, "id-1", read_timeout=10, retry_total=0) is first
    default = azure_connections.blob_service(url, "id-1")
    other = azure_connections.blob_service(url, "id-2", retry_total=0, read_timeout=10)
    assert default is not first and default.credential is first.credential
    assert other.credential is not first.credential
    assert first.options == {"retry_total": 0, "read_timeout": 10}


def test_sdk_request_tracing_is_kept_out_of_the_logs():
    logger = logging.getLogger("azure.core.pipeline.policies.http_logging_policy")
    previous = logger.level
    try:
        logger.setLevel(logging.NOTSET)
        azure_connections.quiet_sdk_http_logging()
        assert not logger.isEnabledFor(logging.INFO) and logger.isEnabledFor(logging.WARNING)
    finally:
        logger.setLevel(previous)


def test_api_shutdown_closes_the_shared_connections(monkeypatch):
    import main

    events = []

    async def close():
        events.append("closed")

    monkeypatch.setattr(main.azure_connections, "aclose", close)
    with TestClient(main.app):
        assert events == []
    assert events == ["closed"]
