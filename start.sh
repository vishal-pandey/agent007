#!/bin/bash
# Local dev: runs on port 8001. AgentCore container uses port 9000 (set via A2A_PORT).
A2A_PORT=${A2A_PORT:-8001} uvicorn agent007.agent:a2a_app --host localhost --port ${A2A_PORT}
