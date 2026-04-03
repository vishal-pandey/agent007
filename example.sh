#!/bin/bash
curl -X POST http://localhost:8001/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "id": "task-001",
      "metadata": {
        "model": "gemini-2.5-flash",
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
