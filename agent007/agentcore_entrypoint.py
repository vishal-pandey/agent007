"""
AgentCore entrypoint for agent007.

Wraps the existing ADK agent with BedrockAgentCoreApp for deployment
to AWS Bedrock AgentCore Runtime.
"""
from dotenv import load_dotenv

load_dotenv("agent007/.env")

from bedrock_agentcore import BedrockAgentCoreApp
from google.adk.runners import RunConfig
from google.genai import types as genai_types

from agent007.agent import create_agent, _make_runner

app = BedrockAgentCoreApp()


@app.entrypoint
async def invoke(payload, context):
    prompt = payload.get("prompt", "Hello!")

    agent = create_agent()
    runner = _make_runner(agent)

    # create_session may be sync or async depending on the ADK version;
    # handle both gracefully.
    import inspect
    result = runner.session_service.create_session(
        app_name="agent007", user_id="agentcore-user"
    )
    if inspect.isawaitable(result):
        session = await result
    else:
        session = result

    response_text = ""
    async for event in runner.run_async(
        user_id="agentcore-user",
        session_id=session.id,
        new_message=genai_types.Content(
            role="user",
            parts=[genai_types.Part(text=prompt)],
        ),
        run_config=RunConfig(),
    ):
        if event.is_final_response() and event.content:
            for part in event.content.parts:
                if hasattr(part, "text") and part.text:
                    response_text += part.text

    return {"response": response_text}


if __name__ == "__main__":
    app.run()
