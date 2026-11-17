"""A thin httpx client over the organizer's REST API.

The client only moves JSON. Every request carries `Authorization: Bearer <token>`: the `api`
token by default, the `mail` token when a call passes `scope="mail"`. The token fixes the author
of any write on the server, so the client sends no author of its own. It drops nothing from a
response and turns failures into `OrganizerError`, whose message is what Claude sees.

For an organizer behind Cloudflare Access, a service token (client id and secret) is sent as
`CF-Access-Client-Id` and `CF-Access-Client-Secret` on every request, so Access lets the call
through to the organizer, which then checks the bearer token as usual.
"""

from __future__ import annotations

import datetime as dt
from collections.abc import Mapping
from typing import Any

import httpx

from organizer_mcp.config import (
    CF_ACCESS_ID_ENV,
    CF_ACCESS_SECRET_ENV,
    TOKEN_ENVS,
    Scope,
    missing_token_message,
)

# FastAPI's own 404 text, and the text the organizer uses for unknown /api paths.
_GENERIC_NOT_FOUND = frozenset({"Not Found", "not found"})


class OrganizerError(Exception):
    """A failed organizer call. The message is written for Claude to act on."""


class OrganizerClient:
    def __init__(
        self,
        base_url: str,
        timeout: float = 15.0,
        transport: httpx.BaseTransport | None = None,
        *,
        token: str | None = None,
        mail_token: str | None = None,
        cf_access_client_id: str | None = None,
        cf_access_client_secret: str | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._tokens: dict[str, str | None] = {"api": token, "mail": mail_token}
        # Sent only as a pair: half a service token is refused by Access anyway.
        access: dict[str, str] = {}
        if cf_access_client_id and cf_access_client_secret:
            access = {
                "CF-Access-Client-Id": cf_access_client_id,
                "CF-Access-Client-Secret": cf_access_client_secret,
            }
        self.uses_access_service_token = bool(access)
        self._http = httpx.Client(
            base_url=self.base_url, timeout=timeout, transport=transport, headers=access
        )

    def close(self) -> None:
        self._http.close()

    def get(
        self, path: str, params: Mapping[str, Any] | None = None, *, scope: Scope = "api"
    ) -> Any:
        return self._request("GET", path, scope, params=params)

    def post(
        self,
        path: str,
        body: Any = None,
        params: Mapping[str, Any] | None = None,
        *,
        scope: Scope = "api",
    ) -> Any:
        return self._request("POST", path, scope, params=params, body=body)

    def put(self, path: str, body: Any = None, *, scope: Scope = "api") -> Any:
        return self._request("PUT", path, scope, body=body)

    def patch(self, path: str, body: Any = None, *, scope: Scope = "api") -> Any:
        return self._request("PATCH", path, scope, body=body)

    def delete(self, path: str, *, scope: Scope = "api") -> Any:
        return self._request("DELETE", path, scope)

    def _request(
        self,
        method: str,
        path: str,
        scope: Scope,
        *,
        params: Mapping[str, Any] | None = None,
        body: Any = None,
    ) -> Any:
        token = self._tokens.get(scope)
        if not token:
            raise OrganizerError(missing_token_message(scope))
        try:
            response = self._http.request(
                method,
                path,
                params=_query(params),
                json=None if body is None else _jsonable(body),
                headers={"Authorization": f"Bearer {token}"},
            )
        except httpx.ReadTimeout as exc:
            raise OrganizerError(
                f"organizer at {self.base_url} did not answer within {self.timeout:g}s "
                f"on {method} {path}"
            ) from exc
        except httpx.TransportError as exc:
            raise OrganizerError(
                f"organizer unreachable at {self.base_url} (is it running, and is ORGANIZER_URL "
                "right?)"
            ) from exc

        if response.is_redirect:
            raise OrganizerError(self._redirect_error(response, method, path))
        if response.status_code >= 400:
            raise OrganizerError(_http_error(response, method, path, scope))
        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError as exc:
            raise OrganizerError(f"organizer returned non-JSON for {method} {path}") from exc

    def _redirect_error(self, response: httpx.Response, method: str, path: str) -> str:
        """A redirect is never an answer the tools can use, so it is an error, not an empty result.

        Cloudflare Access sends a request without a valid service token to its sign-in page.
        """
        target = httpx.URL(response.headers.get("location", ""))
        where = f"{method} {path}"
        if target.host.endswith(".cloudflareaccess.com") or target.path.startswith(
            "/cdn-cgi/access/"
        ):
            fix = (
                f"check the service token in {CF_ACCESS_ID_ENV} and {CF_ACCESS_SECRET_ENV} "
                "(revoked or expired?), and that the Access application has a Service Auth "
                "policy that includes it"
                if self.uses_access_service_token
                else f"set {CF_ACCESS_ID_ENV} and {CF_ACCESS_SECRET_ENV} to a service token, "
                "or point ORGANIZER_URL at an address without Access"
            )
            return (
                f"Cloudflare Access stopped {where} at {self.base_url}: {fix} (docs/CLOUDFLARE.md)"
            )
        return (
            f"organizer at {self.base_url} redirected {where} (HTTP {response.status_code}) to "
            f"{target.copy_with(query=None)}; is ORGANIZER_URL the organizer's own address, or is "
            "a proxy in front of it?"
        )


def _query(params: Mapping[str, Any] | None) -> dict[str, Any] | None:
    """Drop unset parameters and render values the way the API reads them."""
    if not params:
        return None
    query: dict[str, Any] = {}
    for key, value in params.items():
        if value is None:
            continue
        if isinstance(value, list | tuple):
            query[key] = [_scalar(item) for item in value]
        else:
            query[key] = _scalar(value)
    return query or None


def _scalar(value: Any) -> Any:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, dt.date | dt.time):
        return value.isoformat()
    return value


def _jsonable(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _jsonable(item) for key, item in value.items()}
    if isinstance(value, list | tuple):
        return [_jsonable(item) for item in value]
    if isinstance(value, dt.date | dt.time):
        return value.isoformat()
    return value


def _http_error(response: httpx.Response, method: str, path: str, scope: str) -> str:
    status = response.status_code
    where = f"{method} {path}"
    detail = _detail(response)
    if status == 404:
        if not detail or detail in _GENERIC_NOT_FOUND:
            return f"not found: no organizer endpoint at {where}"
        if "not found" in detail.lower():
            return detail
        return f"not found: {detail}"
    if status in (400, 409, 422):
        return detail or f"organizer refused {where} (HTTP {status})"
    if status in (401, 403):
        env = TOKEN_ENVS[scope]
        return (
            f"organizer refused {where} (HTTP {status}): {detail}. Check {env}: it must be a "
            f"live token with the '{scope}' scope (Settings → API tokens)"
        )
    return f"organizer error on {where} (HTTP {status}): {detail}"


def _detail(response: httpx.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        return response.text.strip()[:300]
    detail = body.get("detail") if isinstance(body, dict) else None
    if isinstance(detail, str):
        return detail
    if isinstance(detail, list):
        return "; ".join(_validation_line(item) for item in detail)
    return str(body)[:300]


def _validation_line(item: Any) -> str:
    """One FastAPI validation error as 'field: message'."""
    if not isinstance(item, dict):
        return str(item)
    loc = [str(part) for part in item.get("loc", []) if part not in ("body", "query", "path")]
    message = str(item.get("msg", "invalid value"))
    return f"{'.'.join(loc)}: {message}" if loc else message
