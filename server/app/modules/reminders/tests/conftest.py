"""Fixtures for the reminders tests."""

import pytest
from fastapi.testclient import TestClient

from app.modules.reminders.tests.support import fake_tasks  # noqa: F401


@pytest.fixture
def helper(token_client) -> TestClient:
    """The Mac helper: an ingest-scoped token whose author is `helper`."""
    return token_client(["ingest"], author="helper")
