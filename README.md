# Cluster de Kubernetes (Amazon EKS) con Terraform

Este proyecto crea un cluster de **Amazon EKS (Elastic Kubernetes Service)**
usando **Terraform**, pensado para practicar gastando lo mínimo posible:

- 1 solo nodo `t3a.medium` (2 vCPU / 4 GB RAM).
- Nodo tipo **Spot** (más barato que On-Demand).
- VPC propia con **subredes públicas y sin NAT Gateway**, para evitar su
  costo fijo (~30 USD/mes).
- Disco de 20 GB por nodo.

> Este setup está pensado para **practicar**, no para
> producción: los nodos Spot pueden ser interrumpidos por AWS en
> cualquier momento, y solo hay 1 nodo (sin alta disponibilidad).

## Estructura del proyecto

```
terraform-aws-eks/
├── versions.tf              # Versión de Terraform y del provider de AWS
├── provider.tf               # Configuración del provider de AWS
├── variables.tf               # Variables configurables del proyecto
├── network.tf                 # VPC, subredes públicas, internet gateway
├── iam.tf                       # Roles IAM para el cluster y los nodos
├── eks.tf                        # El cluster de EKS y su node group
├── outputs.tf                     # Datos útiles que Terraform muestra al final
├── terraform.tfvars.example     # Ejemplo de valores (copiar a terraform.tfvars)
└── .gitignore
```

## 1. Requisitos previos

1. **Cuenta de AWS** con un método de pago configurado.
2. **Terraform** instalado (>= 1.5). Verificar con:
   ```bash
   terraform -version
   ```
3. **AWS CLI** instalado. Verificar con:
   ```bash
   aws --version
   ```
4. **kubectl** instalado (para interactuar con el cluster luego).
   ```bash
   kubectl version --client
   ```

Si te falta algo, instalarlo:

- Terraform: https://developer.hashicorp.com/terraform/install
- AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- kubectl: https://kubernetes.io/docs/tasks/tools/#kubectl

## 2. Autenticarte con AWS

Necesitas un usuario/rol de IAM con permisos para crear VPCs, roles IAM,
y clusters de EKS (para practicar, el más simple es usar un usuario con la
policy administrada `AdministratorAccess`; para algo más acotado, se
necesitan permisos de `ec2`, `eks` e `iam`).

```bash
aws configure
```

Te pedirá tu `Access Key ID`, `Secret Access Key`, la región por defecto
(por ejemplo `us-east-1`) y el formato de salida (`json`).

Verifica que quedó bien configurado:

```bash
aws sts get-caller-identity
aws configure list-profiles
aws configure list
export AWS_PROFILE=production
```

## 3. Configurar tus variables

Copia el archivo de ejemplo y edítalo si quieres cambiar algo (los
valores por defecto ya están pensados para ser económicos):

```bash
cp terraform.tfvars.example terraform.tfvars
```

## 4. Inicializar Terraform

Descarga el provider de AWS y prepara la carpeta de trabajo:

```bash
terraform init
```

## 5. Revisar el plan

Terraform te muestra **qué va a crear** antes de tocar nada real:

```bash
terraform plan
```

Deberías ver que va a crear: 1 VPC, subredes, internet gateway, roles
IAM, 1 cluster de EKS y 1 node group (con 1 nodo).

## 6. Crear el cluster

```bash
terraform apply
```

Terraform te vuelve a mostrar el plan y te pide confirmar escribiendo
`yes`. La creación del cluster tarda normalmente entre **10 y 15
minutos** (EKS es más lento que GKE para crear el control plane).

## 7. Conectar `kubectl` al cluster

Al terminar, Terraform muestra un output llamado `get_credentials_command`.
Ejecútalo (o usa este, reemplazando los valores si cambiaste algo):

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-cluster-basic
```

Esto configura tu `~/.kube/config` para que `kubectl` apunte al nuevo
cluster. Como quien aplica el `terraform apply` queda automáticamente
como administrador del cluster (`access_config` en `eks.tf`), no
necesitas configurar nada adicional de permisos.

## 8. Verificar que todo funciona

```bash
kubectl get nodes
```

Deberías ver 1 nodo en estado `Ready` (puede tardar 1-2 minutos después
de que Terraform termine, mientras el nodo se une al cluster). Puedes
probar a desplegar algo:

```bash
kubectl create deployment hello --image=nginx
kubectl get pods
```

## 9. Destruir el cluster (¡importante para no gastar de más!)

Cuando termines de practicar, **destruye los recursos** para dejar de
pagar por ellos:

```bash
terraform destroy --auto-approve
```

Confirma escribiendo `yes`. Esto elimina el node group, el cluster, los
roles IAM y la VPC. Recuerda que **cada hora que el cluster quede
corriendo cuesta dinero** (el control plane de EKS no es gratis), así
que no lo dejes activo si no lo estás usando.

## Notas sobre el costo

- **Control plane de EKS**: ~0.10 USD/hora fijo (≈73 USD/mes si queda
  corriendo un mes completo), independientemente del tamaño o cantidad
  de nodos. Este es el principal costo a vigilar.
- **Nodo**: un `t3a.medium` en modo Spot suele costar unos pocos
  centavos de dólar por hora (varía según la región y la demanda de
  Spot).
- **Red**: se evitó a propósito el NAT Gateway (usando subredes
  públicas) porque cuesta ~0.045 USD/hora + tráfico, para no sumar otro
  costo fijo innecesario en un cluster de aprendizaje.
- Puedes revisar el costo estimado en la
  [calculadora de precios de AWS](https://calculator.aws/).

## Personalizar el proyecto

Todo es configurable desde `variables.tf` / `terraform.tfvars`, por ejemplo:

| Variable             | Qué controla                             |
| -------------------- | ---------------------------------------- |
| `instance_type`      | Tipo de instancia EC2 del nodo (CPU/RAM) |
| `node_count`         | Cantidad de nodos                        |
| `use_spot_instances` | Usar nodos Spot o On-Demand (estables)   |
| `disk_size_gb`       | Tamaño de disco por nodo                 |
| `region`             | Región de AWS donde se crea todo         |
| `kubernetes_version` | Versión de Kubernetes del control plane  |
