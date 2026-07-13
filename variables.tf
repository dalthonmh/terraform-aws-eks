variable "region" {
  description = "Región de AWS donde se crea todo (control plane, VPC, nodo)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nombre del cluster de EKS."
  type        = string
  default     = "eks-cluster-basico"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes del control plane. Si se deja null, AWS usa la versión por defecto vigente."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "Rango CIDR de la VPC creada para el cluster."
  type        = string
  default     = "10.20.0.0/16"
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para el nodo worker."
  type        = string
  default     = "t3a.medium"
}

variable "node_count" {
  description = "Cantidad de nodos worker (min = max = deseado, para mantenerlo simple y barato)."
  type        = number
  default     = 1
}

variable "disk_size_gb" {
  description = "Tamaño del disco (EBS) de cada nodo, en GB."
  type        = number
  default     = 20
}

variable "use_spot_instances" {
  description = "Usar instancias Spot (más baratas, pero pueden ser interrumpidas) en vez de On-Demand."
  type        = bool
  default     = true
}
