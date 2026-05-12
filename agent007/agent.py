import contextvars
import re
from typing import Any, Optional
from urllib.parse import urlparse

import httpx
import yaml

from dotenv import load_dotenv
load_dotenv("agent007/.env")

from google.adk.agents.llm_agent import Agent
from google.adk.a2a.executor.a2a_agent_executor import A2aAgentExecutor
from google.adk.a2a.executor.config import (
    A2aAgentExecutorConfig,
    ExecuteInterceptor,
    RequestContext,
)
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.adk.artifacts import InMemoryArtifactService
from google.adk.memory import InMemoryMemoryService
from google.adk.auth.credential_service.in_memory_credential_service import (
    InMemoryCredentialService,
)
from google.adk.skills import models as skill_models
from google.adk.tools.skill_toolset import SkillToolset
from google.adk.tools.mcp_tool.mcp_toolset import (
    McpToolset,
    StdioConnectionParams,
    SseConnectionParams,
    StreamableHTTPConnectionParams,
)
from mcp import StdioServerParameters
from a2a.server.request_handlers.default_request_handler import (
    DefaultRequestHandler,
)
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.tasks.inmemory_push_notification_config_store import (
    InMemoryPushNotificationConfigStore,
)
from a2a.server.apps.jsonrpc.starlette_app import A2AStarletteApplication
from a2a.types import AgentCard
from starlette.applications import Starlette
from google.adk.tools.base_toolset import BaseToolset


class SafeMcpToolset(BaseToolset):
    """Wrapper around McpToolset that catches connection errors gracefully.

    If the underlying MCP server is unreachable (e.g. localhost from a container),
    this returns an empty tool list instead of crashing the entire request.
    """

    def __init__(self, inner: McpToolset):
        super().__init__(
            tool_filter=inner.tool_filter,
            tool_name_prefix=inner.tool_name_prefix,
        )
        self._inner = inner

    async def get_tools(self, readonly_context=None):
        try:
            return await self._inner.get_tools(readonly_context)
        except (ConnectionError, TimeoutError, OSError, Exception) as e:
            print(f"Warning: MCP server unreachable, skipping tools: {e}")
            return []

    async def close(self):
        try:
            await self._inner.close()
        except Exception:
            pass

    async def process_llm_request(self, *, tool_context, llm_request):
        try:
            return await self._inner.process_llm_request(
                tool_context=tool_context, llm_request=llm_request
            )
        except Exception:
            pass


from google.adk.models.lite_llm import LiteLlm

DEFAULT_MODEL = "gemini/gemini-2.5-flash"
DEFAULT_DESCRIPTION = "A helpful assistant for user questions."
DEFAULT_INSTRUCTION = "Answer user questions to the best of your knowledge"

_request_metadata: contextvars.ContextVar[dict] = contextvars.ContextVar(
    "_request_metadata", default={}
)


def _parse_skill_md(content: str) -> skill_models.Skill:
    """Parse a SKILL.md string into an ADK Skill object."""
    # Split YAML frontmatter from markdown body
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)", content, re.DOTALL)
    if not match:
        raise ValueError("SKILL.md must have YAML frontmatter delimited by ---")

    frontmatter_raw = yaml.safe_load(match.group(1))
    instructions = match.group(2).strip()

    frontmatter = skill_models.Frontmatter(
        name=frontmatter_raw.get("name", "unnamed-skill"),
        description=frontmatter_raw.get("description", ""),
    )

    return skill_models.Skill(
        frontmatter=frontmatter,
        instructions=instructions,
    )


def _resolve_skill_url(skill_ref: str) -> list[str]:
    """Resolve a skill reference to candidate raw SKILL.md URLs.

    Accepts:
      - Full URL: https://raw.githubusercontent.com/.../SKILL.md
      - Shorthand: owner/repo/skill-name (tries common GitHub paths)
    """
    if skill_ref.startswith("http://") or skill_ref.startswith("https://"):
        return [skill_ref]

    parts = skill_ref.split("/")
    if len(parts) == 3:
        owner, repo, skill_name = parts
        base = f"https://raw.githubusercontent.com/{owner}/{repo}/main"
        # Try all common skill directory conventions
        return [
            f"{base}/skills/{skill_name}/SKILL.md",
            f"{base}/plugin/skills/{skill_name}/SKILL.md",
            f"{base}/.claude/skills/{skill_name}/SKILL.md",
            f"{base}/.github/skills/{skill_name}/SKILL.md",
        ]
    elif len(parts) == 2:
        owner, repo = parts
        base = f"https://raw.githubusercontent.com/{owner}/{repo}/main"
        return [f"{base}/SKILL.md"]
    else:
        raise ValueError(
            f"Invalid skill reference: {skill_ref}. "
            "Use 'owner/repo/skill-name' or a full URL."
        )


def _fetch_skills(skill_refs: list[str]) -> list[skill_models.Skill]:
    """Fetch and parse skills from URLs or shorthand references."""
    skills = []
    for ref in skill_refs:
        urls = _resolve_skill_url(ref)
        loaded = False
        for url in urls:
            try:
                resp = httpx.get(url, timeout=10, follow_redirects=True)
                resp.raise_for_status()
                skill = _parse_skill_md(resp.text)
                skills.append(skill)
                loaded = True
                break
            except Exception:
                continue
        if not loaded:
            print(f"Warning: Failed to load skill '{ref}' from any known path")
    return skills


_AGENTCORE_HOST_RE = re.compile(
    r"^bedrock-agentcore(?:\.[a-z0-9-]+)?\.([a-z0-9-]+)\.amazonaws\.com$"
)


def _agentcore_region(url: str) -> Optional[str]:
    """Return the AWS region if `url` points at the Bedrock AgentCore data plane."""
    host = (urlparse(url).hostname or "").lower()
    match = _AGENTCORE_HOST_RE.match(host)
    return match.group(1) if match else None


class _SigV4HttpxAuth(httpx.Auth):
    """Sign each outgoing httpx request with SigV4 for the given service+region.

    AgentCore-hosted MCP servers default to IAM auth, which requires per-request
    SigV4 signing — static headers can't carry it because the signature depends
    on the request body. This auth class re-signs every request using the
    current process credential chain.
    """

    requires_request_body = True

    def __init__(self, service: str, region: str) -> None:
        # Imports are local so users without boto3 can still load this module.
        import boto3
        from botocore.auth import SigV4Auth

        self._session = boto3.Session()
        self._signer_factory = SigV4Auth
        self._service = service
        self._region = region

    def _credentials(self):
        creds = self._session.get_credentials()
        if creds is None:
            raise RuntimeError(
                "No AWS credentials available for SigV4 signing of AgentCore MCP request."
            )
        return creds.get_frozen_credentials()

    def auth_flow(self, request: httpx.Request):
        from botocore.awsrequest import AWSRequest

        # botocore needs the raw body bytes to compute the payload hash.
        body = request.content or b""
        aws_request = AWSRequest(
            method=request.method,
            url=str(request.url),
            data=body,
            headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
        )
        # Force-overwrite any pre-set Authorization header from the caller.
        aws_request.headers.pop("Authorization", None)
        self._signer_factory(
            self._credentials(), self._service, self._region
        ).add_auth(aws_request)
        for header_name, header_value in aws_request.headers.items():
            request.headers[header_name] = header_value
        yield request


def _agentcore_httpx_client_factory(region: str):
    """Return an `httpx_client_factory` that injects SigV4 auth for AgentCore."""
    from mcp.shared._httpx_utils import create_mcp_http_client

    def factory(
        headers: dict[str, str] | None = None,
        timeout: httpx.Timeout | None = None,
        auth: httpx.Auth | None = None,
    ) -> httpx.AsyncClient:
        # If the caller already supplied an auth (e.g. bearer token), respect it.
        return create_mcp_http_client(
            headers=headers,
            timeout=timeout,
            auth=auth or _SigV4HttpxAuth("bedrock-agentcore", region),
        )

    return factory


def _build_mcp_toolsets(mcp_configs: list[dict]) -> list[SafeMcpToolset]:
    """Build McpToolset instances from config dicts.

    Each config dict can be:
      - {"url": "https://..."} for Streamable HTTP servers
      - {"url": "https://...", "transport": "sse"} for SSE servers
      - {"command": "npx", "args": ["-y", "some-mcp-server"]} for stdio servers
      - Optional "headers": {"key": "value"} for auth headers
      - Optional "tool_filter": ["tool1", "tool2"] to limit tools

    When the URL host matches the Bedrock AgentCore data plane, requests are
    SigV4-signed using the local AWS credential chain — no extra config needed
    beyond IAM permission on the agent's execution role.
    """
    toolsets = []
    for cfg in mcp_configs:
        tool_filter = cfg.get("tool_filter")

        if "url" in cfg:
            transport = cfg.get("transport", "http")
            headers = cfg.get("headers", {})
            timeout = cfg.get("timeout", 60)
            agentcore_region = _agentcore_region(cfg["url"])
            extra_kwargs: dict[str, Any] = {}
            if agentcore_region and transport != "sse":
                extra_kwargs["httpx_client_factory"] = _agentcore_httpx_client_factory(
                    agentcore_region
                )
            if transport == "sse":
                params = SseConnectionParams(url=cfg["url"], headers=headers, timeout=timeout)
            else:
                params = StreamableHTTPConnectionParams(
                    url=cfg["url"], headers=headers, timeout=timeout, **extra_kwargs
                )
            toolsets.append(
                SafeMcpToolset(McpToolset(connection_params=params, tool_filter=tool_filter))
            )
        elif "command" in cfg:
            server_params = StdioServerParameters(
                command=cfg["command"],
                args=cfg.get("args", []),
                env=cfg.get("env"),
            )
            params = StdioConnectionParams(
                server_params=server_params,
                timeout=30,
            )
            toolsets.append(
                SafeMcpToolset(McpToolset(connection_params=params, tool_filter=tool_filter))
            )
        else:
            print(f"Warning: Invalid MCP config, needs 'url' or 'command': {cfg}")
    return toolsets


def _resolve_model(model: str):
    """Resolve a model string to the appropriate ADK model object.

    Supported prefixes:
      - "bedrock/<model-id>"  → LiteLlm(model="bedrock/<model-id>")
      - "gemini/<model-id>"   → raw model-id string (native Gemini)
      - bare string           → passed through as-is for backward compat
    """
    if model.startswith("bedrock/"):
        # LiteLlm handles Bedrock via boto3 credential chain
        return LiteLlm(model=model)
    if model.startswith("gemini/"):
        # Strip prefix — ADK handles Gemini model IDs natively
        return model.removeprefix("gemini/")
    # Fallback: pass through as-is (e.g. "gemini-2.5-flash" still works)
    return model


def create_agent(
    model: str = DEFAULT_MODEL,
    description: str = DEFAULT_DESCRIPTION,
    instruction: str = DEFAULT_INSTRUCTION,
    skills: list[skill_models.Skill] | None = None,
    mcp_toolsets: list[SafeMcpToolset] | None = None,
) -> Agent:
    tools: list = []
    if skills:
        tools.append(SkillToolset(skills=skills))
    if mcp_toolsets:
        tools.extend(mcp_toolsets)

    resolved_model = _resolve_model(model)

    return Agent(
        model=resolved_model,
        name="root_agent",
        description=description,
        instruction=instruction,
        tools=tools,
    )


def _make_runner(agent: Agent) -> Runner:
    return Runner(
        agent=agent,
        app_name="agent007",
        session_service=InMemorySessionService(),
        artifact_service=InMemoryArtifactService(),
        memory_service=InMemoryMemoryService(),
        credential_service=InMemoryCredentialService(),
    )


async def _before_agent(ctx: RequestContext) -> RequestContext:
    """Store request metadata in contextvar before runner is resolved."""
    _request_metadata.set(ctx.metadata)
    return ctx


class DynamicRunnerExecutor(A2aAgentExecutor):
    """Subclass that creates a fresh runner per request based on metadata."""

    def __init__(self, *, config: Optional[A2aAgentExecutorConfig] = None):
        super().__init__(runner=self._build_runner, config=config)

    def _build_runner(self) -> Runner:
        meta = _request_metadata.get()
        model = meta.get("model", DEFAULT_MODEL)
        instruction = meta.get("instruction", DEFAULT_INSTRUCTION)
        description = meta.get("description", DEFAULT_DESCRIPTION)
        skill_refs = meta.get("skills", [])
        mcp_configs = meta.get("mcp_servers", [])

        skills = _fetch_skills(skill_refs) if skill_refs else None

        mcp_toolsets = None
        if mcp_configs:
            try:
                mcp_toolsets = _build_mcp_toolsets(mcp_configs)
            except Exception as e:
                print(f"Warning: Failed to build MCP toolsets, continuing without them: {e}")

        agent = create_agent(
            model=model,
            description=description,
            instruction=instruction,
            skills=skills,
            mcp_toolsets=mcp_toolsets,
        )
        return _make_runner(agent)

    async def _resolve_runner(self) -> Runner:
        """Override to always call the factory — never cache."""
        return self._build_runner()


def build_a2a_app(port: int = 8001) -> Starlette:
    interceptor = ExecuteInterceptor(before_agent=_before_agent)
    config = A2aAgentExecutorConfig(execute_interceptors=[interceptor])

    executor = DynamicRunnerExecutor(config=config)

    task_store = InMemoryTaskStore()
    push_config_store = InMemoryPushNotificationConfigStore()

    request_handler = DefaultRequestHandler(
        agent_executor=executor,
        task_store=task_store,
        push_config_store=push_config_store,
    )

    # When deployed on AgentCore, AGENTCORE_RUNTIME_URL is injected automatically.
    # Fall back to localhost for local development.
    import os as _os
    agent_url = _os.environ.get("AGENTCORE_RUNTIME_URL", f"http://localhost:{port}")

    agent_card = AgentCard(
        name="agent007",
        url=agent_url,
        description=DEFAULT_DESCRIPTION,
        version="1.0.0",
        capabilities={},
        skills=[],
        defaultInputModes=["text/plain"],
        defaultOutputModes=["text/plain"],
        supportsAuthenticatedExtendedCard=False,
    )

    a2a_starlette = A2AStarletteApplication(
        agent_card=agent_card,
        http_handler=request_handler,
    )

    return a2a_starlette.build()


import os
_port = int(os.environ.get("A2A_PORT", "8001"))
a2a_app = build_a2a_app(port=_port)

# Keep root_agent for ADK CLI compatibility
root_agent = create_agent()
