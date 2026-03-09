#!/usr/bin/env python3
# raspberry_to_aws_mqtt.py
import RPi.GPIO as GPIO
import board
import adafruit_dht
import time
import json
import paho.mqtt.client as mqtt
import sys
from datetime import datetime
import logging

# Configuración de pines
DHT_PIN = board.D4
MQ135_DO_PIN = 17

# --- NUEVA CONFIGURACIÓN MQTT (Reemplaza API Gateway) ---
MQTT_BROKER_IP = "10.0.1.X" # ⚠️ Reemplazar con la IP PRIVADA de tu EC2
MQTT_PORT = 1883
MQTT_TOPIC = "sensores/iot"

DEVICE_ID = "raspberry-madrid-01"
LOCATION = "Madrid"
LATITUDE = "40.4168"
LONGITUDE = "-3.7038"

# Configurar logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/home/abram/sensor_log.txt'),
        logging.StreamHandler()
    ]
)

class SensorMonitor:
    def __init__(self):
        # Inicializar DHT22
        self.dht_device = adafruit_dht.DHT22(DHT_PIN, use_pulseio=False)

        # Inicializar MQ-135 (digital)
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(MQ135_DO_PIN, GPIO.IN, pull_up_down=GPIO.PUD_DOWN)

        self.device_id = DEVICE_ID
        self.broker_ip = MQTT_BROKER_IP

        logging.info(f"Sensor Monitor inicializado. Sensor ID: {self.device_id}")
        logging.info(f"MQTT Broker: {self.broker_ip}:{MQTT_PORT} | Topic: {MQTT_TOPIC}")

    def read_dht22(self):
        """Leer sensor DHT22"""
        try:
            temperature = self.dht_device.temperature
            humidity = self.dht_device.humidity

            if temperature is not None and humidity is not None:
                return {
                    'temperature': round(temperature, 1),
                    'humidity': round(humidity, 1),
                    'status': 'success'
                }
            else:
                return {'status': 'error', 'message': 'Invalid readings'}

        except RuntimeError as e:
            return {'status': 'error', 'message': str(e)}
        except Exception as e:
            return {'status': 'error', 'message': str(e)}

    def read_mq135(self):
        """Leer sensor MQ-135 (digital)"""
        try:
            estado = GPIO.input(MQ135_DO_PIN)
            air_quality = 'polluted' if estado == GPIO.HIGH else 'clean'

            # Leer múltiples veces para promedio (opcional)
            readings = []
            for _ in range(5):
                readings.append(GPIO.input(MQ135_DO_PIN))
                time.sleep(0.1)

            avg = sum(readings) / len(readings)
            air_quality = 'polluted' if avg > 0.5 else 'clean'

            return {
                'air_quality': air_quality,
                'digital_value': estado,
                'avg_value': avg,
                'status': 'success'
            }

        except Exception as e:
            return {'status': 'error', 'message': str(e)}

    def send_to_aws_mqtt(self, data):
        """Enviar datos al Broker MQTT en la EC2 a través de la VPN"""
        try:
            client = mqtt.Client()
            # Conectar a la IP privada de la EC2 por el túnel VPN
            client.connect(self.broker_ip, MQTT_PORT, 60)
            
            # Publicar el JSON
            payload = json.dumps(data)
            client.publish(MQTT_TOPIC, payload)
            
            logging.info(f"Datos publicados en MQTT: {payload}")
            client.disconnect()
            return True

        except Exception as e:
            logging.error(f"Error enviando vía MQTT/VPN: {e}")
            return False

    def collect_and_send(self):
        """Recolectar datos y enviar al broker MQTT"""
        logging.info("=== Iniciando lectura de sensores ===")

        # Leer sensores
        dht_data = self.read_dht22()
        mq135_data = self.read_mq135()

        # Preparar payload compatible con la Lambda de Terraform
        # Nota: La Lambda espera 'sensor_id' para DynamoDB
        payload = {
            'sensor_id': self.device_id, 
            'location': LOCATION,
            'latitude': LATITUDE,
            'longitude': LONGITUDE,
            'read_time': datetime.now().isoformat()
        }

        # Agregar datos DHT22 si exitosos
        if dht_data['status'] == 'success':
            payload['temperature'] = dht_data['temperature']
            payload['humidity'] = dht_data['humidity']
        else:
            logging.warning(f"Error DHT22: {dht_data.get('message')}")
            payload['temperature'] = None
            payload['humidity'] = None

        # Agregar datos MQ-135 si exitosos
        if mq135_data['status'] == 'success':
            payload['air_quality'] = mq135_data['air_quality']
            payload['mq135_value'] = mq135_data['avg_value']
        else:
            logging.warning(f"Error MQ135: {mq135_data.get('message')}")
            payload['air_quality'] = 'unknown'

        # Enviar vía MQTT
        success = self.send_to_aws_mqtt(payload)

        # Guardar localmente (backup)
        self.save_local_backup(payload, success)

        return success

    def save_local_backup(self, data, aws_success):
        """Guardar datos localmente como backup"""
        try:
            backup_file = '/home/abram/sensor_backup.json'

            # Cargar datos existentes
            existing_data = []
            try:
                with open(backup_file, 'r') as f:
                    existing_data = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError):
                existing_data = []

            # Agregar nuevo dato
            data['aws_success'] = aws_success
            data['local_timestamp'] = datetime.now().isoformat()
            existing_data.append(data)

            # Mantener solo últimas 1000 lecturas
            if len(existing_data) > 1000:
                existing_data = existing_data[-1000:]

            # Guardar
            with open(backup_file, 'w') as f:
                json.dump(existing_data, f, indent=2)

            logging.info(f"Datos guardados localmente. Total: {len(existing_data)} registros")

        except Exception as e:
            logging.error(f"Error guardando backup: {e}")

    def run_continuous(self, interval_seconds=60):
        """Ejecutar monitoreo continuo"""
        logging.info(f"Iniciando monitoreo continuo MQTT. Intervalo: {interval_seconds}s")
        logging.info("Ctrl+C para detener")

        stats = {'success': 0, 'failed': 0, 'total': 0}

        try:
            while True:
                stats['total'] += 1

                success = self.collect_and_send()

                if success:
                    stats['success'] += 1
                else:
                    stats['failed'] += 1

                # Mostrar estadísticas cada 10 lecturas
                if stats['total'] % 10 == 0:
                    success_rate = (stats['success'] / stats['total']) * 100
                    logging.info(f"Estadísticas: {stats['success']}/{stats['total']} exitosas ({success_rate:.1f}%)")

                # Esperar para siguiente lectura
                time.sleep(interval_seconds)

        except KeyboardInterrupt:
            logging.info("\nMonitoreo detenido por usuario")
            self.cleanup()

            # Mostrar resumen final
            success_rate = (stats['success'] / stats['total']) * 100 if stats['total'] > 0 else 0
            logging.info(f"\n=== RESUMEN FINAL ===")
            logging.info(f"Total lecturas: {stats['total']}")
            logging.info(f"Exitosas: {stats['success']} ({success_rate:.1f}%)")
            logging.info(f"Fallidas: {stats['failed']}")

        except Exception as e:
            logging.error(f"Error en monitoreo: {e}")
            self.cleanup()

    def cleanup(self):
        """Limpiar recursos GPIO"""
        try:
            self.dht_device.exit()
            GPIO.cleanup()
            logging.info("Recursos GPIO liberados")
        except:
            pass

# Script principal
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description='Monitor de sensores Raspberry Pi a AWS vía MQTT/VPN')
    parser.add_argument('--interval', type=int, default=60, help='Intervalo entre lecturas en segundos')
    parser.add_argument('--test', action='store_true', help='Modo prueba (solo una lectura)')
    parser.add_argument('--mqtt-ip', help='IP privada de la EC2 (Broker MQTT)')

    args = parser.parse_args()

    # Sobreescribir IP del Broker si se proporciona por argumento
    if args.mqtt_ip:
        MQTT_BROKER_IP = args.mqtt_ip

    monitor = SensorMonitor()

    if args.test:
        print("=== MODO PRUEBA ===")
        success = monitor.collect_and_send()
        print(f"Resultado: {'Éxito' if success else 'Fallo'}")
        monitor.cleanup()
    else:
        monitor.run_continuous(args.interval)