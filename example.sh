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
        "instruction": "You only answer questions in 1 line only without fail",
        "description": "A one-line answer bot"
      },
      "message": {
        "role": "user",
        "messageId": "msg-001",
        "parts": [
          {
            "kind": "text",
            "text": "How do I read a CSV file?"
          }
        ]
      }
    }
  }'
