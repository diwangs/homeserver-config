"""Run from a patched Hermes checkout under tests/gateway/ with run_tests.sh."""

from unittest.mock import MagicMock

import pytest
from aiohttp.test_utils import TestClient, TestServer

from gateway.config import Platform
from tests.gateway.test_api_server import _create_app, _make_adapter
from tests.gateway.test_proxy_mode import _make_runner, _make_source


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("source_platform", "expected_platform"),
    [(Platform.MATRIX, "matrix"), (Platform.TELEGRAM, "api_server")],
)
async def test_proxy_preserves_presentation_and_api_tool_policy(
    monkeypatch, source_platform, expected_platform
):
    """Exercise real proxy HTTP, request parsing, executor and agent construction."""
    agent = MagicMock()
    agent.run_conversation.return_value = {"final_response": "**Formatted reply**"}
    agent.session_prompt_tokens = 1
    agent.session_completion_tokens = 1
    agent.session_total_tokens = 2
    constructor = MagicMock(return_value=agent)
    monkeypatch.setattr("run_agent.AIAgent", constructor)
    monkeypatch.setattr("gateway.run._resolve_runtime_agent_kwargs", lambda: {})
    monkeypatch.setattr("gateway.run._resolve_gateway_model", lambda: "test-model")
    monkeypatch.setattr("gateway.run._load_gateway_config", lambda: {})
    monkeypatch.setattr("gateway.run.GatewayRunner._load_reasoning_config", lambda *_: {})
    monkeypatch.setattr("gateway.run.GatewayRunner._load_fallback_model", lambda: None)
    tool_policy = MagicMock(return_value=set())
    monkeypatch.setattr("hermes_cli.tools_config._get_platform_tools", tool_policy)
    monkeypatch.setenv("GATEWAY_PROXY_KEY", "overlay-test-key")
    adapter = _make_adapter(api_key="overlay-test-key")
    monkeypatch.setattr(adapter, "_ensure_session_db", lambda: None)

    async with TestServer(_create_app(adapter)) as server:
        monkeypatch.setenv("GATEWAY_PROXY_URL", str(server.make_url("")).rstrip("/"))
        result = await _make_runner()._run_agent_via_proxy(
            message="Format this reply", context_prompt="", history=[],
            source=_make_source(source_platform), session_id="overlay-test-session",
        )

    assert result["final_response"] == "**Formatted reply**"
    assert constructor.call_args.kwargs["platform"] == expected_platform
    assert all(call.args[1] == "api_server" for call in tool_policy.call_args_list)
    assert tool_policy.called


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("origin", "api_key", "expected_status"),
    [("matrix", "", 403), ("desktop", "overlay-test-key", 400),
     ({"platform": "matrix"}, "overlay-test-key", 400)],
)
async def test_origin_override_requires_auth_and_supported_platform(origin, api_key, expected_status):
    adapter = _make_adapter(api_key=api_key)
    async with TestClient(TestServer(_create_app(adapter))) as client:
        response = await client.post(
            "/v1/chat/completions",
            headers={"Authorization": f"Bearer {api_key}"} if api_key else {},
            json={"hermes_origin_platform": origin,
                  "messages": [{"role": "user", "content": "hi"}]},
        )
        assert response.status == expected_status
