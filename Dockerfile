FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY agent007/ ./agent007/

# Expose the application port
EXPOSE 8001

# Run the application (use 0.0.0.0 to accept external connections)
CMD ["uvicorn", "agent007.agent:a2a_app", "--host", "0.0.0.0", "--port", "8001"]
