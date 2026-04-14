FROM python:3.12-slim

# Install Node.js for npx-based MCP servers
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent007/ agent007/

# AgentCore A2A protocol requires port 9000
EXPOSE 9000

CMD ["uvicorn", "agent007.agent:a2a_app", "--host", "0.0.0.0", "--port", "9000"]
