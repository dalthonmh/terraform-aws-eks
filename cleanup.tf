# Limpieza de dependencias huérfanas antes de destruir la red.
#
# Al hacer `terraform destroy`, la VPC no se puede eliminar si quedan recursos
# que EKS/Kubernetes crearon POR FUERA de Terraform y que siguen colgando de
# ella: Load Balancers (Services type LoadBalancer / Ingress), los security
# groups que administra EKS y las ENIs que tardan en liberarse. Terraform no
# los conoce, así que AWS responde con "DependencyViolation" al borrar la VPC.
#
# ORDEN (lo importante):
#   Este null_resource depende SOLO de la red (VPC/subredes/etc.), y el cluster
#   y el node group dependen de ÉL (ver depends_on en eks.tf). Como en un
#   destroy el orden es inverso al de creación, la secuencia queda:
#
#     1. destruir node group + cluster   (libera la mayoría de ENIs y SGs)
#     2. correr esta limpieza            (borra LBs, ENIs y SGs que quedaron)
#     3. destruir subredes / IGW / VPC
#
#   OJO: la limpieza NO debe depender del cluster/node group. Si lo hiciera, se
#   destruiría ANTES que ellos y correría con el cluster todavía vivo, sin poder
#   borrar nada (fue el bug original).
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

  # Solo la RED. El cluster/node group dependen de este recurso, no al revés.
  depends_on = [
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

      # 3. ENIs y security groups. AWS tarda en liberar las ENIs de los LB, y
      #    algunas quedan 'in-use' un rato; por eso reintentamos varias veces.
      for intento in 1 2 3 4 5 6; do
        echo "   -- intento $intento de limpieza de ENIs/SGs"

        # 3a. ENIs 'in-use' que ya no tienen dueño gestionado: intentar
        #     desasociarlas para que pasen a 'available'.
        for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "NetworkInterfaces[?Status=='in-use' && Attachment.InstanceId==null].NetworkInterfaceId" \
            --output text); do
          att=$(aws ec2 describe-network-interfaces --region "$REGION" \
              --network-interface-ids "$eni" \
              --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
          if [ -n "$att" ] && [ "$att" != "None" ]; then
            echo "   - desasociando ENI $eni ($att)"
            aws ec2 detach-network-interface --region "$REGION" --attachment-id "$att" --force || true
          fi
        done

        # 3b. ENIs disponibles: borrarlas.
        for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
            --output text); do
          echo "   - eliminando ENI $eni"
          aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" || true
        done

        # 3c. Security groups no-default. Primero revocamos sus reglas para
        #     romper referencias cruzadas, y recién después los borramos.
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

        # ¿Quedan dependencias? Si no, salimos del loop.
        pend_eni=$(aws ec2 describe-network-interfaces --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "length(NetworkInterfaces)" --output text)
        pend_sg=$(aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query "length(SecurityGroups[?GroupName!='default'])" --output text)
        if [ "$pend_eni" = "0" ] && [ "$pend_sg" = "0" ]; then
          echo "   -- sin dependencias pendientes"
          break
        fi
        echo "   -- quedan ENIs=$pend_eni SGs=$pend_sg; esperando 20s..."
        sleep 20
      done

      echo ">> Limpieza terminada"
    EOT
  }
}
