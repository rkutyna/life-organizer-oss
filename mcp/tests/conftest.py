"""The `organizer` fixture: the shared client pointed at a FakeOrganizer, with both tokens."""

from __future__ import annotations

from collections.abc import Iterator

import httpx
import pytest
from support import API_TOKEN, BASE_URL, MAIL_TOKEN, FakeOrganizer

from organizer_mcp import server
from organizer_mcp.client import OrganizerClient


@pytest.fixture
def organizer() -> Iterator[FakeOrganizer]:
    fake = FakeOrganizer()
    client = OrganizerClient(
        BASE_URL,
        timeout=5,
        transport=httpx.MockTransport(fake),
        token=API_TOKEN,
        mail_token=MAIL_TOKEN,
    )
    server.use_client(client)
    try:
        yield fake
    finally:
        server.use_client(None)
        client.close()
