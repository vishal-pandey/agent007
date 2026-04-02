import contextvars
from typing import Callable, Awaitable, Optional

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


DEFAULT_MODEL = "gemini--flash"
DEFAULT_DESCRIPTION = "A helpful assistant for user questions."
DEFAULT_INSTRUCTION = "Answer user questions to the best of your knowledge"

# Context var to pass metadata from interceptor to runner factory
_request_metadata: contextvars.ContextVar[dict] = contextvars.ContextVar(
    "_request_metadata", default={}
)


def create_agent(
    model: str = DEFAULT_MODEL,
    description: str = DEFAULT_DESCRIPTION,
    instruction: str = DEFAULT_INSTRUCTION,
) -> Agent:
    return Agent(
        model=model,
        name="root_agent",
        description=description,
        instruction=instruction,
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
        # Pass a dummy callable to satisfy the parent constructor
        super().__init__(runner=self._build_runner, config=config)

    def _build_runner(self) -> Runner:
        meta = _request_metadata.get()
        model = meta.get("model", DEFAULT_MODEL)
        instruction = meta.get("instruction", DEFAULT_INSTRUCTION)
        description = meta.get("description", DEFAULT_DESCRIPTION)
        agent = create_agent(
            model=model, description=description, instruction=instruction
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
