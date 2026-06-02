import paho.mqtt.publish as publish
import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()

BROKER_HOST = os.getenv("MQTT_HOST", "localhost")
BROKER_PORT  = int(os.getenv("MQTT_PORT", "1883"))

class AlertPayload(BaseModel):
    topic:   str
    message: str

@app.post("/publish")
def publicar_alerta(payload: AlertPayload):
    try:
        publish.single(
            topic    = payload.topic,
            payload  = payload.message,
            hostname = BROKER_HOST,
            port     = BROKER_PORT
        )
        print(f"[MQTT API] Publicado en '{payload.topic}': {payload.message}")
        return {"status": "ok", "topic": payload.topic}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
def health():
    return {"status": "mqtt-service activo"}