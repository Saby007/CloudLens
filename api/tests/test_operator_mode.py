"""Dev-only operator mode: no Entra sign-in, one configured operator, reachable only through port-forward."""

import asyncio
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from services import auth
from services.auth import require_tenant_principal

TENANT_ID = "11111111-1111-1111-1111-111111111111"
OPERATOR_ID = "66666666-6666-6666-6666-666666666666"
OPERATOR_UPN = "operator@example.test"
INGRESS_HEADERS = ["forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip"]


@pytest.fixture(autouse=True)
def _operator_mode(monkeypatch):
    monkeypatch.setenv("MEGHKOSHA_AUTH_MODE", "operator")
    monkeypatch.setenv("MEGHKOSHA_OPERATOR_OBJECT_ID", OPERATOR_ID)
    monkeypatch.setenv("MEGHKOSHA_OPERATOR_UPN", OPERATOR_UPN)
    monkeypatch.delenv("MEGHKOSHA_API_CLIENT_ID", raising=False)
    monkeypatch.delenv("MEGHKOSHA_WEB_CLIENT_ID", raising=False)
    monkeypatch.delenv("APP_WEB_INGRESS_RESTRICTED", raising=False)

    def no_token_validation(request, expected_tenant_id):
        raise AssertionError("Operator mode must not validate Entra tokens.")

    monkeypatch.setattr(auth, "resolve_user_token", no_token_validation)


def _request(headers=None):
    return SimpleNamespace(headers=headers or {})


def test_operator_mode_acts_as_the_configured_operator_without_any_token():
    principal = require_tenant_principal(_request(), TENANT_ID)

    assert principal.entra_object_id == OPERATOR_ID
    assert principal.tenant_id == TENANT_ID
    assert principal.user_details == OPERATOR_UPN
    assert principal.actor == f"{TENANT_ID}:operator:{OPERATOR_ID}"
    assert principal.user_assertion == ""


@pytest.mark.parametrize("header", INGRESS_HEADERS)
def test_operator_mode_refuses_requests_forwarded_by_the_public_ingress(header):
    with pytest.raises(HTTPException) as error:
        require_tenant_principal(_request({header: "203.0.113.7"}), TENANT_ID)
    assert error.value.status_code == 403


@pytest.mark.parametrize("header", INGRESS_HEADERS)
def test_operator_mode_accepts_the_public_ingress_once_https_is_on_an_ip_allow_list(monkeypatch, header):
    monkeypatch.setenv("APP_WEB_INGRESS_RESTRICTED", "true")
    principal = require_tenant_principal(_request({header: "203.0.113.7"}), TENANT_ID)
    assert principal.entra_object_id == OPERATOR_ID


@pytest.mark.parametrize("restricted", ["", "false", "True", " true", "1", "yes"])
def test_only_an_exactly_applied_allow_list_opens_the_public_ingress(monkeypatch, restricted):
    monkeypatch.setenv("APP_WEB_INGRESS_RESTRICTED", restricted)
    with pytest.raises(HTTPException) as error:
        require_tenant_principal(_request({"x-forwarded-for": "203.0.113.7"}), TENANT_ID)
    assert error.value.status_code == 403


@pytest.mark.parametrize("raw", ["", "invalid", "00000000-0000-0000-0000-000000000000"])
def test_operator_mode_fails_closed_without_a_configured_operator(monkeypatch, raw):
    monkeypatch.setenv("MEGHKOSHA_OPERATOR_OBJECT_ID", raw)
    with pytest.raises(HTTPException) as error:
        require_tenant_principal(_request(), TENANT_ID)
    assert error.value.status_code == 503
    assert OPERATOR_UPN not in error.value.detail


@pytest.mark.parametrize("tenant", ["", "tenant-1", "00000000-0000-0000-0000-000000000000"])
def test_operator_mode_still_requires_the_configured_deployment_tenant(tenant):
    with pytest.raises(HTTPException) as error:
        require_tenant_principal(_request(), tenant)
    assert error.value.status_code == 503


@pytest.mark.parametrize("mode", ["Operator", " operator", "operator ", "none", "anonymous"])
def test_an_unrecognized_auth_mode_fails_closed_instead_of_guessing(monkeypatch, mode):
    monkeypatch.setenv("MEGHKOSHA_AUTH_MODE", mode)
    with pytest.raises(HTTPException) as error:
        require_tenant_principal(_request(), TENANT_ID)
    assert error.value.status_code == 503


@pytest.mark.parametrize("mode", [None, "", "entra"])
def test_entra_sign_in_stays_the_default_and_still_requires_a_token(monkeypatch, mode):
    if mode is None:
        monkeypatch.delenv("MEGHKOSHA_AUTH_MODE")
    else:
        monkeypatch.setenv("MEGHKOSHA_AUTH_MODE", mode)
    calls = []

    def entra(request, expected_tenant_id):
        calls.append(expected_tenant_id)
        raise HTTPException(status_code=401, detail="A valid delegated API bearer token is required.")

    monkeypatch.setattr(auth, "resolve_user_token", entra)
    with pytest.raises(HTTPException) as error:
        require_tenant_principal(_request(), TENANT_ID)
    assert error.value.status_code == 401
    assert calls == [TENANT_ID]


@pytest.mark.parametrize("upn", ["", "   ", "two words@example.test", "x" * 321, "bell\u0007@example.test"])
def test_an_unusable_operator_name_falls_back_to_the_object_id(monkeypatch, upn):
    monkeypatch.setenv("MEGHKOSHA_OPERATOR_UPN", upn)
    assert require_tenant_principal(_request(), TENANT_ID).user_details == OPERATOR_ID


def test_http_boundary_serves_the_operator_only_to_port_forwarded_requests():
    from fastapi.testclient import TestClient
    import main

    with TestClient(main.app) as client:
        response = client.get("/api/auth/config")
        assert response.status_code == 200
        assert response.json() == {"mode": "operator", "tenantId": TENANT_ID}
        assert response.headers["cache-control"] == "no-store"
        response = client.get("/api/auth/me")
        assert response.status_code == 200
        profile = response.json()
        assert (profile["userId"], profile["userDetails"], profile["tenantId"]) == (
            f"operator:{OPERATOR_ID}", OPERATOR_UPN, TENANT_ID)
        for header in INGRESS_HEADERS:
            forwarded = {header: "203.0.113.7"}
            assert client.get("/api/auth/config", headers=forwarded).status_code == 403
            assert client.get("/api/auth/me", headers=forwarded).status_code == 403


def test_http_boundary_serves_the_allow_listed_public_url(monkeypatch):
    from fastapi.testclient import TestClient
    import main

    monkeypatch.setenv("APP_WEB_INGRESS_RESTRICTED", "true")
    forwarded = {"x-forwarded-for": "203.0.113.7", "x-real-ip": "203.0.113.7", "x-forwarded-proto": "https"}
    with TestClient(main.app) as client:
        response = client.get("/api/auth/config", headers=forwarded)
        assert response.status_code == 200
        assert response.json() == {"mode": "operator", "tenantId": TENANT_ID}
        response = client.get("/api/auth/me", headers=forwarded)
        assert response.status_code == 200
        assert response.json()["userId"] == f"operator:{OPERATOR_ID}"


def test_subscription_authorization_runs_against_the_operator_role_assignments(monkeypatch):
    import main

    async def list_subscriptions():
        return [{"subscriptionId": "sub-1", "displayName": "Sub One"},
                {"subscriptionId": "sub-2", "displayName": "Sub Two"}]

    async def authorized_subscriptions(principal_object_id, subscription_ids):
        assert principal_object_id == OPERATOR_ID
        return [subscription_ids[0]]

    monkeypatch.setattr(main.arm_client, "list_subscriptions", list_subscriptions)
    monkeypatch.setattr(main.access_control, "authorized_subscription_ids", authorized_subscriptions)
    result = asyncio.run(main.get_subscriptions(_request()))
    assert [item["subscriptionId"] for item in result] == ["sub-1"]
