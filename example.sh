#!/bin/bash

# Example: Gemini model (use gemini/ prefix or bare model name)
curl -X POST https://agent007.codeshare.co.in/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "id": "task-001",
      "metadata": {
        "model": "gemini/gemini-2.5-flash",
        "instruction": "You are an Azure cloud infrastructure expert. Use your loaded skills to provide accurate, actionable guidance.",
        "description": "Azure infrastructure assistant with skills",
        "skills": [
          "microsoft/GitHub-Copilot-for-Azure/azure-ai",
          "microsoft/GitHub-Copilot-for-Azure/azure-deploy"
        ]
      },
      "message": {
        "role": "user",
        "messageId": "msg-001",
        "parts": [
          {
            "kind": "text",
            "text": "How do I set up Azure AI Search with vector search?"
          }
        ]
      }
    }
  }'



# Example to use mcp server dynamically
curl -X POST https://agent007.codeshare.co.in/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "2",
    "method": "message/send",
    "params": {
      "id": "task-002",
      "metadata": {
        "model": "gemini/gemini-2.5-flash",
        "instruction": "You are a helpful assistant.",
        "description": "Bedrock Claude assistant",
        "mcp_servers": [
          {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
        ]
      },
      "message": {
        "role": "user",
        "messageId": "msg-001",
        "parts": [
          {
            "kind": "text",
            "text": "Explain how VPCs work in AWS"
          }
        ]
      }
    }
  }'


# Example: Invoke deployed agent on Bedrock AgentCore (uses awscurl for SigV4 signing)
# awscurl automatically picks up SSO/IAM credentials from your AWS profile
AGENT_ARN="arn:aws:bedrock-agentcore:us-east-1:813923511679:runtime/agent007-Ew26m0BY4C"
ENCODED_ARN=$(python3 -c "from urllib.parse import quote; print(quote('$AGENT_ARN', safe=''))")
SESSION_ID=$(uuidgen)

awscurl -X POST "https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/${ENCODED_ARN}/invocations/" \
  -H "Content-Type: application/json" \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: ${SESSION_ID}" \
  --region us-east-1 \
  --service bedrock-agentcore \
  -d '{
    "jsonrpc": "2.0",
    "id": "2",
    "method": "message/send",
    "params": {
      "id": "task-002",
      "metadata": {
        "model": "bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0",
        "instruction": "You are a helpful assistant.",
        "description": "Bedrock Claude assistant"
      },
      "message": {
        "role": "user",
        "messageId": "msg-001",
        "parts": [
          {
            "kind": "text",
            "text": "Explain how VPCs work in AWS"
          }
        ]
      }
    }
  }'
