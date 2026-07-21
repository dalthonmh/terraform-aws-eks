resource "aws_eks_cluster" "main" {
  name                      = var.cluster_name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = []

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  # Modo de autenticación moderno: permite dar acceso vía "access entries"
  # (aws_eks_access_entry) sin tocar el configmap aws-auth a mano.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    # El cluster depende de la limpieza para que, en el destroy, se elimine
    # ANTES que ella (y la limpieza corra con el cluster ya destruido).
    null_resource.vpc_cleanup,
  ]

  tags = {
    Name = var.cluster_name
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id

  instance_types = [var.instance_type]
  capacity_type  = var.use_spot_instances ? "SPOT" : "ON_DEMAND"
  disk_size      = var.disk_size_gb

  scaling_config {
    min_size     = var.node_count
    max_size     = var.node_count
    desired_size = var.node_count
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
    # Igual que el cluster: se destruye antes que la limpieza.
    null_resource.vpc_cleanup,
  ]

  tags = {
    Name = "${var.cluster_name}-node"
  }
}
