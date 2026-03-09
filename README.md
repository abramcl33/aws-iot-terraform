# 📡 IoT Sensor Platform — Terraform IaC

Infraestructura como código (Terraform) para una plataforma IoT completa que recoge datos de sensores físicos desde una **Raspberry Pi**, los procesa en AWS y los publica en un **dashboard web en tiempo real**.

---

## 🏗️ Arquitectura

```
┌─────────────────────────────────────────────────────────────────────────┐
│  RED LOCAL                          AWS (VPC: 10.0.0.0/16)              │
│                                                                          │
│  ┌─────────────┐   IPSec VPN    ┌──────────────────────────────────┐    │
│  │ Raspberry Pi│ ─────────────► │  EC2 (broker MQTT)               │    │
│  │  Sensores:  │  Site-to-Site  │  Amazon Linux 2023 + Mosquitto   │    │
│  │  · Temp     │                │  Subred pública 10.0.1.0/24      │    │
│  │  · Humedad  │                └──────────────┬───────────────────┘    │
│  │  · Presión  │                               │ HTTP POST              │
│  └─────────────┘                               ▼                        │
│                                  ┌─────────────────────────┐            │
│                                  │   API Gateway (REST)    │            │
│                                  │   POST /sensor-data     │            │
│                                  │   GET  /sensor-data     │            │
│                                  └────────┬────────────────┘            │
│                                           │                             │
│                        ┌──────────────────┴──────────────────┐         │
│                        ▼                                      ▼         │
│             ┌─────────────────────┐              ┌──────────────────┐  │
│             │  Lambda 1           │              │  Lambda 2        │  │
│             │  ingest-sensor-data │              │  publish-to-s3   │  │
│             │  (Python 3.12)      │              │  (Python 3.12)   │  │
│             └──────────┬──────────┘              └────────┬─────────┘  │
│                        │ PutItem                          │ Scan        │
│                        ▼                                  │             │
│             ┌─────────────────────┐                       │             │
│             │     DynamoDB        │ ◄─────────────────────┘             │
│             │  sensor-data        │                       │             │
│             │  PK: sensor_id      │            PutObject  │             │
│             │  SK: timestamp      │                       ▼             │
│             └─────────────────────┘          ┌────────────────────┐    │
│                                              │  S3 Static Website │    │
│                      EventBridge             │  index.html        │    │
│                      (cada 1 min) ──────────►│  data.json         │    │
│                                              └────────────────────┘    │
│                                                       │                 │
└───────────────────────────────────────────────────────┼─────────────────┘
                                                        │ HTTP
                                                        ▼
                                              👤 Usuario Final
                                           (Dashboard en el navegador)
```

---

## 📁 Estructura del proyecto

```
.
├── main.tf          # Recursos AWS: VPC, EC2, VPN, Lambda, DynamoDB, S3, API Gateway
├── variables.tf     # Declaración de todas las variables configurables
├── outputs.tf       # Valores exportados tras terraform apply
├── .gitignore       # ⚠️ Excluye .terraform/, *.tfstate y *.tfvars de Git
└── README.md        # Este archivo
```

---

## 🔄 Flujo de datos

1. **Raspberry Pi** lee sensores (temperatura, humedad, presión) y los envía por MQTT a la EC2 a través del túnel VPN IPSec.
2. **EC2** (broker Mosquitto) recibe los mensajes MQTT y hace un `POST /sensor-data` al API Gateway con el payload JSON.
3. **API Gateway** invoca **Lambda 1** (`ingest-sensor-data`), que escribe el registro en **DynamoDB**.
4. **EventBridge** dispara **Lambda 2** (`publish-to-s3`) cada minuto; esta función lee los últimos 100 registros de DynamoDB y actualiza `data.json` en el **bucket S3**.
5. El **dashboard web** (HTML estático en S3) carga `data.json` cada 30 segundos y muestra los datos en pantalla.

---

## ⚙️ Variables principales

| Variable | Descripción | Default |
|---|---|---|
| `aws_region` | Región AWS donde desplegar | `eu-west-1` |
| `project_name` | Prefijo para nombrar todos los recursos | `iot-sensor-project` |
| `vpc_cidr` | Bloque CIDR de la VPC | `10.0.0.0/16` |
| `raspberry_pi_ip` | **IP pública real de la Raspberry Pi** | `0.0.0.0` ⚠️ |
| `ec2_instance_type` | Tipo de instancia EC2 | `t3.micro` |
| `ec2_key_pair_name` | Key Pair SSH existente en AWS | `iot-ec2-keypair` ⚠️ |

> ⚠️ Las variables marcadas **deben** cambiarse antes de ejecutar `terraform apply`.

---

## 🚀 Despliegue

### Prerequisitos

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0
- [AWS CLI](https://aws.amazon.com/cli/) configurado (`aws configure`)
- Un Key Pair creado en tu cuenta AWS

### Pasos

```bash
# 1. Clonar el repositorio
git clone <tu-repo>
cd <tu-repo>

# 2. Crear archivo de variables (NO subir a Git)
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con tu IP de Raspberry Pi y Key Pair

# 3. Inicializar Terraform
terraform init

# 4. Revisar el plan de cambios
terraform plan

# 5. Aplicar la infraestructura
terraform apply
```

### Outputs tras el despliegue

```
ec2_public_ip        = "X.X.X.X"
vpn_tunnel1_address  = "Y.Y.Y.Y"   ← Configurar en strongSwan de la Raspberry Pi
vpn_tunnel2_address  = "Z.Z.Z.Z"   ← Failover
api_gateway_url      = "https://<id>.execute-api.eu-west-1.amazonaws.com/prod/sensor-data"
s3_website_url       = "http://<bucket>.s3-website-eu-west-1.amazonaws.com"
dynamodb_table_name  = "iot-sensor-project-sensor-data"
```

### Destruir la infraestructura

```bash
terraform destroy
```

---

## 🔐 Seguridad

- El archivo `.gitignore` excluye `.terraform/`, `*.tfstate` y `*.tfvars` — **nunca subas estos archivos a GitHub**, contienen claves y el estado completo de tu infraestructura.
- El Security Group de la EC2 solo permite tráfico MQTT (`1883`, `8883`) desde la subred de la Raspberry Pi (`192.168.1.0/24`).
- En producción, restringe el acceso SSH (`puerto 22`) a tu IP específica en lugar de `0.0.0.0/0`.
- Considera añadir autenticación al API Gateway (`API_KEY` o `AWS_IAM`) para el endpoint de ingestión.

---

## 🛠️ Configuración VPN en la Raspberry Pi

Tras el `terraform apply`, configura **strongSwan** en la Raspberry Pi con las IPs de los dos túneles del output:

```bash
sudo apt install strongswan -y
# Editar /etc/ipsec.conf y /etc/ipsec.secrets con las IPs de los túneles
# y el pre-shared key que puedes obtener desde la consola de AWS VPN
```

---

## 📸 Capturas del proyecto

### ⚡ Terraform Apply — Despliegue de infraestructura
![Terraform apply completado](images/Captura%20de%20pantalla%202026-03-09%20035405.png)

### 🌐 VPC — Red privada en AWS
![VPC creada en AWS](images/Captura%20de%20pantalla%202026-03-09%20035436.png)

### 🔒 VPN — Túnel IPSec desde la terminal
![Túnel VPN activo en terminal](images/Captura%20de%20pantalla%202026-03-09%20035506.png)

### 🔒 VPN — Conexión Site-to-Site en AWS
![VPN Site-to-Site configurada](images/Captura%20de%20pantalla%202026-03-09%20035538.png)

### 🖥️ EC2 — Broker MQTT
![Instancia EC2 corriendo](images/Captura%20de%20pantalla%202026-03-09%20041046.png)

### ⚡ Lambda 1 — Ingestión de datos (EC2 → DynamoDB)
![Lambda ingest-sensor-data](images/Captura%20de%20pantalla%202026-03-09%20041142.png)

### ⚡ Lambda 2 — Publicación (DynamoDB → S3)
![Lambda publish-to-s3](images/Captura%20de%20pantalla%202026-03-09%20041309.png)

### 🗄️ DynamoDB — Tabla de datos de sensores
![Tabla DynamoDB con registros](images/Captura%20de%20pantalla%202026-03-09%20041334.png)

### 📊 Dashboard Web — Visualización en tiempo real
![Dashboard IoT en S3](images/Captura%20de%20pantalla%202026-03-09%20041545.png)

---

## 📦 Tecnologías utilizadas

- **Terraform** — IaC
- **AWS VPC** — Red privada aislada
- **AWS Site-to-Site VPN** — Túnel IPSec seguro
- **Amazon EC2** — Broker MQTT (Mosquitto)
- **AWS Lambda** — Procesamiento serverless (Python 3.12)
- **Amazon DynamoDB** — Base de datos de series temporales
- **Amazon S3** — Hosting web estático del dashboard
- **Amazon API Gateway** — Endpoint REST
- **Amazon EventBridge** — Scheduler para actualizar dashboard
