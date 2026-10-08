"""Principals derived from validated delegated API bearer tokens, or from the Dev operator in operator mode."""

from __future__ import annotations

from dataclasses import dataclass, field

from fastapi import Request
from services.entra_tokens import resolve_user_token
from services.operator_identity import operator_identity, operator_mode_enabled


@dataclass(frozen=True)
class ClientPrincipal:
    user_id: str
    user_details: str
    tenant_id: str
    entra_object_id: str
    user_assertion: str = field(default="", repr=False, compare=False)

    @property
    def actor(self) -> str:
        return f"{self.tenant_id}:{self.user_id}"


def require_tenant_principal(request: Request, expected_tenant_id: str) -> ClientPrincipal:
    if operator_mode_enabled():
        operator = operator_identity(request, expected_tenant_id)
        return ClientPrincipal(user_id=f"operator:{operator.object_id}", user_details=operator.display_name,
                               tenant_id=operator.tenant_id, entra_object_id=operator.object_id)
    identity = resolve_user_token(request, expected_tenant_id)
    return ClientPrincipal(user_id=identity.subject, user_details=identity.display_name,
                           tenant_id=identity.tenant_id, entra_object_id=identity.object_id,
                           user_assertion=identity.user_assertion)