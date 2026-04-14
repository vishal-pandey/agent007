#!/bin/bash

# Example: Gemini model (use gemini/ prefix or bare model name)
curl -X POST http://localhost:8001/ \
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


# Example: Bedrock model (use bedrock/ prefix)
# Auth uses boto3 credential chain (env vars, IAM role, etc.)
curl -X POST http://localhost:8001/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "2",
    "method": "message/send",
    "params": {
      "id": "task-002",
      "metadata": {
        "model": "bedrock/us.anthropic.claude-3-sonnet-20240229-v1:0",
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
