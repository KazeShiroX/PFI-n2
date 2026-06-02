FROM python:3.11-slim

RUN apt-get update && apt-get install -y mosquitto && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD mosquitto -c /app/mosquitto.conf -d && \
    python -u antifraud.py & \
    uvicorn mqtt_api:app --host 0.0.0.0 --port 9000