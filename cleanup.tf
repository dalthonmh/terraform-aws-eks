# Limpieza de dependencias huérfanas antes de destruir la red.
#
# Al hacer `terraform destroy`, la VPC no se puede eliminar si quedan recursos
# que EKS/Kubernetes crearon POR FUERA de Terraform y que siguen colgando de
# ella: Load Balancers (Services type LoadBalancer / Ingress), los security
# groups que administra EKS y las ENIs que tardan en liberarse. Terraform no
# los conoce, así que AWS responde con "DependencyViolation" al borrar la VPC.
#
# Este null_resource corre un provisioner de destroy que los elimina. Gracias
# al depends_on sobre los recursos de red, en el destroy (que va en orden
# inverso a la creación) este bloque se ejecuta ANTES de borrar VPC/subredes.
#
# Requiere tener instalados `aws` CLI y `jq` (el mismo aws que ya usas para
# `update-kubeconfig`).

resource "null_resource" "vpc_cleanup" {
  # Los provisioners de destroy solo pueden leer self.triggers, así que
  # guardamos ahí lo que necesita el script.
  triggers = {
    vpc_id = aws_vpc.main.id
    region = var.region
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_cluster.main,
    aws_vpc.main,
    aws_subnet.public,
    aws_internet_gateway.main,
    aws_route_table.public,
    aws_route_table_association.public,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      VPC_ID="${self.triggers.vpc_id}"
      REGION="${self.triggers.region}"

      echo ">> Limpiando dependencias huérfanas de la VPC $VPC_ID ($REGION)"

      # 1. Load Balancers v2 (ALB / NLB) creados por Services o Ingress.
      for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
          --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
          --output text); do
        echo "   - eliminando load balancer $arn"
        aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || true
      done

      # 2. Load Balancers clásicos (ELB).
      for name in $(aws elb describe-load-balancers --region "$REGION" \
          --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" \
          --output text); do
        echo "   - eliminando classic ELB $name"
        aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name" || true
      done

      # Darle tiempo a AWS a soltar las ENIs asociadas a los LB.
      sleep 30

      # 3. ENIs huérfanas (ya desasociadas: status 'available').
      for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
          --output text); do
        echo "   - eliminando ENI $eni"
        aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
      done

      # 4. Security groups no-default (los crea EKS y el LB controller).
      #    Primero revocamos sus reglas para romper referencias cruzadas
      #    entre security groups, y recién después los borramos.
      SGS=$(aws ec2 describe-security-groups --region "$REGION" \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)

      for sg in $SGS; do
        ingress=$(aws ec2 describe-security-groups --region "$REGION" \
            --group-ids "$sg" --query "SecurityGroups[0].IpPermissions" --output json)
        if [ "$ingress" != "[]" ] && [ -n "$ingress" ]; then
          aws ec2 revoke-security-group-ingress --region "$REGION" \
              --group-id "$sg" --ip-permissions "$ingress" >/dev/null 2>&1 || true
        fi
        egress=$(aws ec2 describe-security-groups --region "$REGION" \
            --group-ids "$sg" --query "SecurityGroups[0].IpPermissionsEgress" --output json)
        if [ "$egress" != "[]" ] && [ -n "$egress" ]; then
          aws ec2 revoke-security-group-egress --region "$REGION" \
              --group-id "$sg" --ip-permissions "$egress" >/dev/null 2>&1 || true
        fi
      done

      for sg in $SGS; do
        echo "   - eliminando security group $sg"
        aws ec2 delete-security-group --region "$REGION" --group-id "$sg" || true
      done

      echo ">> Limpieza terminada"
    EOT
  }
}
