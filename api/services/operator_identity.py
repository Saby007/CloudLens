"""Dev-only operator mode: every request acts as one configured operator instead of a signed-in user.

For environments whose operators cannot create the Entra app registrations that sign-in needs.
MEGHKOSHA_AUTH_MODE=operator makes the API act as MEGHKOSHA_OPERATOR_OBJECT_ID, so access_control.py
still checks that operator's own Azure role assignments on every subscription. Without sign-in, the network
decides who gets in: the public ingress is closed (web/manifests/web.tmpl.yaml), leaving `kubectl port-forward`,
which the cluster limits to Entra-authenticated, Azure RBAC-authorized users, unless Terraform has limited HTTPS
to an IP allow-list (APP_WEB_INGRESS_RESTRICTED=true), in which case the public URL answers only those addresses.
"""

from __future__ import annotations

from dataclasses import dataclass
import os

from fastapi import HTTPException

from services.entra_tokens import configured_uuid

AUTH_MODE_SETTING = "MEGHKOSHA_AUTH_MODE"
OPERATOR_MODE = "operator"
_ENTRA_MODES = frozenset({"", "entra"})
# The public ingress controller sets these on every request it forwards; a port-forwarded request has none.
_INGRESS_HEADERS = ("forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip")
_UNAVAILABLE = "Server identity configuration is unavailable."


@dataclass(frozen=True)
class OperatorIdentity:
    tenant_id: str
    object_id: str
    display_name: str


def operator_mode_enabled() -> bool:
    # Compared exactly, as the web manifest does, so a near miss cannot switch only one of them.
    mode = os.environ.get(AUTH_MODE_SETTING, "")
    if mode == OPERATOR_MODE:
        return True
    if mode in _ENTRA_MODES:
        return False
    raise HTTPException(status_code=503, detail=_UNAVAILABLE)


def operator_identity(request, expected_tenant_id: str) -> OperatorIdentity:
    try:
        tenant_id = configured_uuid(expected_tenant_id)
        object_id = configured_uuid(os.environ.get("MEGHKOSHA_OPERATOR_OBJECT_ID"))
    except (ValueError, TypeError) as error:
        raise HTTPException(status_code=503, detail=_UNAVAILABLE) from error
    if (os.environ.get("APP_WEB_INGRESS_RESTRICTED") != "true"
            and any(request.headers.get(name) is not None for name in _INGRESS_HEADERS)):
        raise HTTPException(status_code=403, detail="Operator mode accepts requests only through kubectl port-forward.")
    display_name = os.environ.get("MEGHKOSHA_OPERATOR_UPN", "").strip()
    if (not display_name or len(display_name) > 320 or not display_name.isprintable()
            or any(character.isspace() for character in display_name)):
        display_name = object_id
    return OperatorIdentity(tenant_id=tenant_id, object_id=object_id, display_name=display_name)
