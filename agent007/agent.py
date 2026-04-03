import contextvars
import re
from typing import Optional

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


DEFAULT_MODEL = "gemini-2.5-flash"
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


def _build_mcp_toolsets(mcp_configs: list[dict]) -> list[McpToolset]:
    """Build McpToolset instances from config dicts.

    Each config dict can be:
      - {"url": "https://..."} for Streamable HTTP servers
      - {"url": "https://...", "transport": "sse"} for SSE servers
      - {"command": "npx", "args": ["-y", "some-mcp-server"]} for stdio servers
      - Optional "headers": {"key": "value"} for auth headers
      - Optional "tool_filter": ["tool1", "tool2"] to limit tools
    """
    toolsets = []
    for cfg in mcp_configs:
        tool_filter = cfg.get("tool_filter")

        if "url" in cfg:
            transport = cfg.get("transport", "http")
            headers = cfg.get("headers", {})
            if transport == "sse":
                params = SseConnectionParams(url=cfg["url"], headers=headers)
            else:
                params = StreamableHTTPConnectionParams(
                    url=cfg["url"], headers=headers
                )
            toolsets.append(
                McpToolset(connection_params=params, tool_filter=tool_filter)
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
                McpToolset(connection_params=params, tool_filter=tool_filter)
            )
        else:
            print(f"Warning: Invalid MCP config, needs 'url' or 'command': {cfg}")
    return toolsets


def create_agent(
    model: str = DEFAULT_MODEL,
    description: str = DEFAULT_DESCRIPTION,
    instruction: str = DEFAULT_INSTRUCTION,
    skills: list[skill_models.Skill] | None = None,
    mcp_toolsets: list[McpToolset] | None = None,
) -> Agent:
    tools: list = []
    if skills:
        tools.append(SkillToolset(skills=skills))
    if mcp_toolsets:
        tools.extend(mcp_toolsets)

    return Agent(
        model=model,
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
        mcp_toolsets = _build_mcp_toolsets(mcp_configs) if mcp_configs else None

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

    agent_card = AgentCard(
        name="agent007",
        url=f"http://localhost:{port}",
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


a2a_app = build_a2a_app(port=8001)

# Keep root_agent for ADK CLI compatibility
root_agent = create_agent()
