output "cluster_name" {
  description = "Nombre del cluster de EKS."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint del API server del cluster."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_status" {
  description = "Estado del cluster."
  value       = aws_eks_cluster.main.status
}

output "region" {
  description = "Región de AWS donde se creó el cluster."
  value       = var.region
}

output "get_credentials_command" {
  description = "Comando para configurar kubectl apuntando a este cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}
