# ============================================================
# OUTPUTS — Valores útiles tras terraform apply
# ============================================================

output "vpc_id" {
  description = "ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "ec2_public_ip" {
  description = "IP pública (Elastic IP) de la EC2 — broker MQTT"
  value       = aws_eip.ec2_eip.public_ip
}

output "vpn_connection_id" {
  description = "ID de la conexión VPN Site-to-Site"
  value       = aws_vpn_connection.raspberry_vpn.id
}

output "vpn_tunnel1_address" {
  description = "Dirección IP del túnel VPN 1 — configurar en la Raspberry Pi (strongSwan / OpenSwan)"
  value       = aws_vpn_connection.raspberry_vpn.tunnel1_address
}

output "vpn_tunnel2_address" {
  description = "Dirección IP del túnel VPN 2 — failover automático"
  value       = aws_vpn_connection.raspberry_vpn.tunnel2_address
}

output "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB donde se almacenan los datos de sensores"
  value       = aws_dynamodb_table.sensor_data.name
}

output "s3_website_url" {
  description = "URL pública del dashboard web alojado en S3"
  value       = "http://${aws_s3_bucket_website_configuration.web_dashboard.website_endpoint}"
}

output "api_gateway_url" {
  description = "Endpoint del API Gateway para POST (ingerir) y GET (consultar) datos"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/sensor-data"
}

output "lambda_ingest_name" {
  description = "Nombre de Lambda 1 — ingestión EC2 → DynamoDB"
  value       = aws_lambda_function.ingest_sensor_data.function_name
}

output "lambda_publish_name" {
  description = "Nombre de Lambda 2 — publicación DynamoDB → S3"
  value       = aws_lambda_function.publish_to_s3.function_name
}
