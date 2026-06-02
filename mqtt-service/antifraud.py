import paho.mqtt.client as mqtt
import json
import os

BROKER_HOST = os.getenv("MQTT_HOST", "localhost")
BROKER_PORT  = int(os.getenv("MQTT_PORT", "1883"))
TOPIC        = "transfers/alerts"

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        client.subscribe(TOPIC)
        print(f"[ANTIFRAUD] Conectado y suscrito a '{TOPIC}'")
    else:
        print(f"[ANTIFRAUD] Error de conexión, código: {rc}")

import requests

def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload.decode())
        amount  = float(payload.get("amount", 0))
        tx_id   = payload.get("txId", "desconocido")

        print(f"[ANTIFRAUD] Alerta recibida — txId: {tx_id} | monto: ${amount}")

        if amount >= 10000:
            print(f"[ANTIFRAUD] ⚠ Transacción sospechosa detectada: {tx_id} por ${amount}")
            node1_url = os.getenv("NODE1_URL")
            if node1_url:
                url = f"{node1_url}/servlet/fraud-result"
                print(f"[ANTIFRAUD] Notificando resultado al Servlet del Nodo 1 en: {url}")
                resp = requests.post(url, json={"txId": tx_id, "flagged": True})
                print(f"[ANTIFRAUD] Respuesta del Nodo 1: {resp.status_code} | {resp.text}")
            else:
                print("[ANTIFRAUD] Advertencia: NODE1_URL no configurado en las variables de entorno.")

    except Exception as e:
        print(f"[ANTIFRAUD] Error procesando mensaje: {e}")

client = mqtt.Client()
client.on_connect = on_connect
client.on_message = on_message

print(f"[ANTIFRAUD] Conectando a broker {BROKER_HOST}:{BROKER_PORT}...")
client.connect(BROKER_HOST, BROKER_PORT, keepalive=60)
client.loop_forever()