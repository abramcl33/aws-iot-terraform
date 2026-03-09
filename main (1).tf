# ============================================================
# ARQUITECTURA IoT: Raspberry Pi → VPN → EC2 → Lambda → DynamoDB → S3
# ============================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================
# VPC Y RED
# ============================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# Subred pública (EC2 + VPN Gateway)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

# Subred privada (Lambdas con acceso a VPC si fuera necesario)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name    = "${var.project_name}-private-subnet"
    Project = var.project_name
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# Tabla de rutas pública
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ============================================================
# VPN SITE-TO-SITE (EC2 ↔ Raspberry Pi)
# ============================================================

# Customer Gateway → representa la Raspberry Pi
resource "aws_customer_gateway" "raspberry_pi" {
  bgp_asn    = 65000
  ip_address = var.raspberry_pi_ip
  type       = "ipsec.1"

  tags = {
    Name    = "${var.project_name}-raspberry-cgw"
    Project = var.project_name
  }
}

# Virtual Private Gateway → lado AWS
resource "aws_vpn_gateway" "vgw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-vgw"
    Project = var.project_name
  }
}

# Conexión VPN Site-to-Site
resource "aws_vpn_connection" "raspberry_vpn" {
  vpn_gateway_id      = aws_vpn_gateway.vgw.id
  customer_gateway_id = aws_customer_gateway.raspberry_pi.id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = {
    Name    = "${var.project_name}-vpn-connection"
    Project = var.project_name
  }
}

# Ruta estática VPN → subred de la Raspberry Pi (ajustar CIDR según red local)
resource "aws_vpn_connection_route" "raspberry_subnet" {
  vpn_connection_id      = aws_vpn_connection.raspberry_vpn.id
  destination_cidr_block = "192.168.1.0/24" # Red local de la Raspberry Pi
}

# Propagar rutas VPN a la tabla de rutas pública
resource "aws_vpn_gateway_route_propagation" "public" {
  vpn_gateway_id = aws_vpn_gateway.vgw.id
  route_table_id = aws_route_table.public.id
}

# ============================================================
# SECURITY GROUPS
# ============================================================

# Security Group para la EC2
resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "SG para la EC2 que recibe datos de la Raspberry Pi por VPN"
  vpc_id      = aws_vpc.main.id

  # SSH (administración)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restringir a tu IP en producción
  }

  # Puerto de aplicación para recibir datos de sensores desde Raspberry Pi
  ingress {
    description = "Sensor data from Raspberry Pi via VPN"
    from_port   = 8883
    to_port     = 8883
    protocol    = "tcp"
    cidr_blocks = ["192.168.1.0/24"] # Red local Raspberry Pi
  }

  # MQTT estándar
  ingress {
    description = "MQTT"
    from_port   = 1883
    to_port     = 1883
    protocol    = "tcp"
    cidr_blocks = ["192.168.1.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ec2-sg"
    Project = var.project_name
  }
}

# ============================================================
# EC2
# ============================================================

# AMI más reciente de Amazon Linux 2023
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM Role para EC2 (invocar Lambda)
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy" "ec2_lambda_invoke" {
  name = "${var.project_name}-ec2-lambda-invoke"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.ingest_sensor_data.arn]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Instancia EC2
resource "aws_instance" "sensor_broker" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name               = var.ec2_key_pair_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y mosquitto mosquitto-clients python3 python3-pip
    pip3 install boto3 paho-mqtt

    # Habilitar e iniciar Mosquitto (broker MQTT)
    systemctl enable mosquitto
    systemctl start mosquitto

    echo "EC2 broker MQTT iniciado. Listo para recibir datos de la Raspberry Pi."
  EOF

  tags = {
    Name    = "${var.project_name}-sensor-broker"
    Project = var.project_name
  }
}

# Elastic IP para la EC2
resource "aws_eip" "ec2_eip" {
  instance = aws_instance.sensor_broker.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-ec2-eip"
    Project = var.project_name
  }
}

# ============================================================
# DYNAMODB
# ============================================================

resource "aws_dynamodb_table" "sensor_data" {
  name         = "${var.project_name}-sensor-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sensor_id"
  range_key    = "timestamp"

  attribute {
    name = "sensor_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name    = "${var.project_name}-sensor-data"
    Project = var.project_name
  }
}

# ============================================================
# S3 - PÁGINA WEB ESTÁTICA
# ============================================================

resource "aws_s3_bucket" "web_dashboard" {
  bucket = "${var.project_name}-web-dashboard-${random_id.suffix.hex}"

  tags = {
    Name    = "${var.project_name}-web-dashboard"
    Project = var.project_name
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_website_configuration" "web_dashboard" {
  bucket = aws_s3_bucket.web_dashboard.id

  index_document { suffix = "index.html" }
  error_document { key    = "error.html" }
}

resource "aws_s3_bucket_public_access_block" "web_dashboard" {
  bucket                  = aws_s3_bucket.web_dashboard.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "web_dashboard_public" {
  bucket     = aws_s3_bucket.web_dashboard.id
  depends_on = [aws_s3_bucket_public_access_block.web_dashboard]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.web_dashboard.arn}/*"
    }]
  })
}

# HTML de dashboard de ejemplo
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.web_dashboard.id
  key          = "index.html"
  content_type = "text/html"

  content = <<-HTML
    <!DOCTYPE html>
    <html lang="es">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Dashboard Sensores IoT</title>
      <style>
        body { font-family: Arial, sans-serif; background: #1a1a2e; color: #eee; margin: 0; padding: 20px; }
        h1 { color: #e94560; text-align: center; }
        .card { background: #16213e; border-radius: 8px; padding: 20px; margin: 10px; display: inline-block; min-width: 200px; }
        .value { font-size: 2em; color: #0f3460; color: #e94560; font-weight: bold; }
        #data-container { text-align: center; }
      </style>
    </head>
    <body>
      <h1>📡 Dashboard IoT - Sensores Raspberry Pi</h1>
      <div id="data-container">
        <div class="card">
          <p>Temperatura</p>
          <div class="value" id="temp">-- °C</div>
        </div>
        <div class="card">
          <p>Humedad</p>
          <div class="value" id="hum">-- %</div>
        </div>
        <div class="card">
          <p>Último update</p>
          <div class="value" id="ts" style="font-size:0.9em">--</div>
        </div>
      </div>
      <script>
        // Actualizar con datos del API Gateway
        async function fetchData() {
          try {
            const res = await fetch('/sensor-data'); // Sustituir por URL del API Gateway
            const data = await res.json();
            if (data.Items && data.Items.length > 0) {
              const latest = data.Items[data.Items.length - 1];
              document.getElementById('temp').textContent = latest.temperature + ' °C';
              document.getElementById('hum').textContent = latest.humidity + ' %';
              document.getElementById('ts').textContent = latest.timestamp;
            }
          } catch(e) { console.error(e); }
        }
        fetchData();
        setInterval(fetchData, 30000);
      </script>
    </body>
    </html>
  HTML
}

# ============================================================
# IAM ROLES PARA LAMBDAS
# ============================================================

# Role Lambda 1: ingerir datos → DynamoDB
resource "aws_iam_role" "lambda_ingest_role" {
  name = "${var.project_name}-lambda-ingest-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy" "lambda_ingest_policy" {
  name = "${var.project_name}-lambda-ingest-policy"
  role = aws_iam_role.lambda_ingest_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.sensor_data.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Role Lambda 2: leer DynamoDB → S3
resource "aws_iam_role" "lambda_publish_role" {
  name = "${var.project_name}-lambda-publish-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy" "lambda_publish_policy" {
  name = "${var.project_name}-lambda-publish-policy"
  role = aws_iam_role.lambda_publish_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Scan", "dynamodb:Query", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.sensor_data.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.web_dashboard.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ============================================================
# LAMBDA 1: EC2 → DynamoDB (ingestión de datos de sensores)
# ============================================================

data "archive_file" "lambda_ingest_zip" {
  type        = "zip"
  output_path = "/tmp/lambda_ingest.zip"

  source {
    content  = <<-PYTHON
import json
import boto3
import os
from datetime import datetime, timezone
import uuid

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ['DYNAMODB_TABLE']

def handler(event, context):
    """
    Recibe datos de sensores enviados por la EC2 y los almacena en DynamoDB.
    Payload esperado:
    {
        "sensor_id": "sensor_001",
        "temperature": 23.5,
        "humidity": 60.2,
        "pressure": 1013.25,
        "location": "sala_principal"
    }
    """
    try:
        table = dynamodb.Table(TABLE_NAME)

        # Soporta invocación directa y via API Gateway
        if isinstance(event.get('body'), str):
            body = json.loads(event['body'])
        elif isinstance(event.get('body'), dict):
            body = event['body']
        else:
            body = event

        timestamp = datetime.now(timezone.utc).isoformat()
        item = {
            'sensor_id':   body.get('sensor_id', f'sensor_{uuid.uuid4().hex[:8]}'),
            'timestamp':   timestamp,
            'temperature': str(body.get('temperature', 0)),
            'humidity':    str(body.get('humidity', 0)),
            'pressure':    str(body.get('pressure', 0)),
            'location':    body.get('location', 'unknown'),
            'raw_data':    json.dumps(body),
        }

        table.put_item(Item=item)
        print(f"Datos guardados: {item}")

        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'message': 'Datos guardados correctamente', 'timestamp': timestamp})
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "ingest_sensor_data" {
  function_name    = "${var.project_name}-ingest-sensor-data"
  role             = aws_iam_role.lambda_ingest_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_ingest_zip.output_path
  source_code_hash = data.archive_file.lambda_ingest_zip.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.sensor_data.name
    }
  }

  tags = {
    Name    = "${var.project_name}-ingest-sensor-data"
    Project = var.project_name
  }
}

# ============================================================
# LAMBDA 2: DynamoDB → S3 (publicar dashboard)
# ============================================================

data "archive_file" "lambda_publish_zip" {
  type        = "zip"
  output_path = "/tmp/lambda_publish.zip"

  source {
    content  = <<-PYTHON
import json
import boto3
import os
from datetime import datetime, timezone
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

TABLE_NAME  = os.environ['DYNAMODB_TABLE']
BUCKET_NAME = os.environ['S3_BUCKET']

class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)

def handler(event, context):
    """
    Lee los últimos datos de DynamoDB y actualiza el archivo data.json
    en el bucket S3 para que el dashboard web los consuma.
    Se puede disparar por: API Gateway GET /sensor-data, EventBridge (cron), o DynamoDB Streams.
    """
    try:
        table = dynamodb.Table(TABLE_NAME)

        # Obtener los últimos 100 registros
        response = table.scan(Limit=100)
        items = response.get('Items', [])

        # Ordenar por timestamp descendente
        items.sort(key=lambda x: x.get('timestamp', ''), reverse=True)

        # Preparar payload para el dashboard
        dashboard_data = {
            'last_updated': datetime.now(timezone.utc).isoformat(),
            'total_records': len(items),
            'Items': items
        }

        json_content = json.dumps(dashboard_data, cls=DecimalEncoder, ensure_ascii=False, indent=2)

        # Subir data.json al bucket S3
        s3.put_object(
            Bucket=BUCKET_NAME,
            Key='data.json',
            Body=json_content.encode('utf-8'),
            ContentType='application/json',
            CacheControl='no-cache, no-store, must-revalidate'
        )

        print(f"data.json actualizado con {len(items)} registros en s3://{BUCKET_NAME}/data.json")

        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps(dashboard_data, cls=DecimalEncoder)
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
    PYTHON
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "publish_to_s3" {
  function_name    = "${var.project_name}-publish-to-s3"
  role             = aws_iam_role.lambda_publish_role.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_publish_zip.output_path
  source_code_hash = data.archive_file.lambda_publish_zip.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.sensor_data.name
      S3_BUCKET      = aws_s3_bucket.web_dashboard.bucket
    }
  }

  tags = {
    Name    = "${var.project_name}-publish-to-s3"
    Project = var.project_name
  }
}

# EventBridge: disparar Lambda 2 cada minuto para actualizar el dashboard
resource "aws_cloudwatch_event_rule" "publish_schedule" {
  name                = "${var.project_name}-publish-schedule"
  description         = "Actualizar dashboard S3 cada minuto"
  schedule_expression = "rate(1 minute)"

  tags = { Project = var.project_name }
}

resource "aws_cloudwatch_event_target" "publish_lambda_target" {
  rule      = aws_cloudwatch_event_rule.publish_schedule.name
  target_id = "PublishToS3Lambda"
  arn       = aws_lambda_function.publish_to_s3.arn
}

resource "aws_lambda_permission" "allow_eventbridge_publish" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.publish_to_s3.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.publish_schedule.arn
}

# ============================================================
# API GATEWAY
# ============================================================

resource "aws_api_gateway_rest_api" "sensor_api" {
  name        = "${var.project_name}-api"
  description = "API para recibir datos de sensores (EC2→Lambda) y servir dashboard (Lambda→S3)"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = { Project = var.project_name }
}

# ---- Recurso /sensor-data ----

resource "aws_api_gateway_resource" "sensor_data" {
  rest_api_id = aws_api_gateway_rest_api.sensor_api.id
  parent_id   = aws_api_gateway_rest_api.sensor_api.root_resource_id
  path_part   = "sensor-data"
}

# POST /sensor-data → Lambda 1 (ingerir)
resource "aws_api_gateway_method" "post_sensor_data" {
  rest_api_id   = aws_api_gateway_rest_api.sensor_api.id
  resource_id   = aws_api_gateway_resource.sensor_data.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_sensor_data_integration" {
  rest_api_id             = aws_api_gateway_rest_api.sensor_api.id
  resource_id             = aws_api_gateway_resource.sensor_data.id
  http_method             = aws_api_gateway_method.post_sensor_data.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.ingest_sensor_data.invoke_arn
}

resource "aws_lambda_permission" "allow_apigw_ingest" {
  statement_id  = "AllowAPIGWIngest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest_sensor_data.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.sensor_api.execution_arn}/*/*"
}

# GET /sensor-data → Lambda 2 (publicar/leer)
resource "aws_api_gateway_method" "get_sensor_data" {
  rest_api_id   = aws_api_gateway_rest_api.sensor_api.id
  resource_id   = aws_api_gateway_resource.sensor_data.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_sensor_data_integration" {
  rest_api_id             = aws_api_gateway_rest_api.sensor_api.id
  resource_id             = aws_api_gateway_resource.sensor_data.id
  http_method             = aws_api_gateway_method.get_sensor_data.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.publish_to_s3.invoke_arn
}

resource "aws_lambda_permission" "allow_apigw_publish" {
  statement_id  = "AllowAPIGWPublish"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.publish_to_s3.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.sensor_api.execution_arn}/*/*"
}

# Deploy del API Gateway
resource "aws_api_gateway_deployment" "sensor_api_deploy" {
  depends_on = [
    aws_api_gateway_integration.post_sensor_data_integration,
    aws_api_gateway_integration.get_sensor_data_integration,
  ]

  rest_api_id = aws_api_gateway_rest_api.sensor_api.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.sensor_api_deploy.id
  rest_api_id   = aws_api_gateway_rest_api.sensor_api.id
  stage_name    = "prod"

  tags = { Project = var.project_name }
}


