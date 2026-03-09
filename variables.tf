# ============================================================
# VARIABLES
# ============================================================

variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Nombre del proyecto (se usa como prefijo en todos los recursos)"
  type        = string
  default     = "iot-sensor-project"
}

variable "vpc_cidr" {
  description = "Bloque CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "raspberry_pi_ip" {
  description = "IP pública de la Raspberry Pi (extremo Customer Gateway de la VPN)"
  type        = string
  default     = "0.0.0.0" # ⚠️ REEMPLAZAR con la IP pública real de la Raspberry Pi
}

variable "ec2_instance_type" {
  description = "Tipo de instancia EC2 para el broker MQTT"
  type        = string
  default     = "t3.micro"
}

variable "ec2_key_pair_name" {
  description = "Nombre del Key Pair de AWS para acceso SSH a la EC2"
  type        = string
  default     = "iot-ec2-keypair" # ⚠️ Debe existir previamente en tu cuenta AWS
}
