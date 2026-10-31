# o cluster nasce e morre com a sessao: plano de controle, nos e add-ons cobram por
# hora, e nada do que roda nele precisa sobreviver ao fim do trabalho.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = "${var.name_prefix}eks"
  kubernetes_version = "1.37"
  upgrade_policy     = { support_type = "STANDARD" }

  # quem aplica este root e o usuario de operacao, e e ele quem opera o cluster do
  # laptop: o criador entra como administrador, e o resto do acesso e por access
  # entry, sem o configmap de autenticacao legado.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # endpoint publico e privado: o pipeline roda num runner fora da VPC e o kubectl
  # roda do laptop. a protecao e identidade (access entries), e nao rede: as faixas
  # de endereco dos runners sao grandes e mudam sem aviso.
  endpoint_public_access = true

  # sem log do plano de controle e sem chave propria: o grupo de log seria recriado
  # depois do destroy, e a chave ficaria dias em exclusao pendente, sujando a conta
  # a cada sessao. o envelope encryption padrao, com chave da AWS, ja cobre os
  # Secrets.
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null

  # credencial de pod so por Pod Identity: IRSA mal configurado falha em silencio,
  # com o pod caindo na credencial do no.
  enable_irsa = false

  vpc_id     = data.aws_vpc.satelite.id
  subnet_ids = [for k in ["a", "b"] : data.aws_subnet.publica[k].id]

  # versao fixa em cada add-on: o padrao do modulo e a mais recente, e sem fixar
  # cada sessao pegaria a do dia. estas sao as medidas no spike.
  addons = {
    vpc-cni = {
      addon_version  = "v1.23.2-eksbuild.3"
      before_compute = true
    }
    eks-pod-identity-agent = {
      addon_version  = "v1.4.0-eksbuild.4"
      before_compute = true
    }
    kube-proxy = {
      addon_version = "v1.37.0-eksbuild.22"
    }
    coredns = {
      addon_version = "v1.14.7-eksbuild.11"
    }
    metrics-server = {
      addon_version = "v0.9.0-eksbuild.13"
    }
    aws-ebs-csi-driver = {
      addon_version = "v1.67.1-eksbuild.1"
      # a associacao nasce junto do add-on para o controller ja subir com a
      # credencial, sem reinicio depois.
      pod_identity_association = [{
        role_arn        = data.aws_iam_role.pod["ebs-csi"].arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # dois nos porque o que esgota primeiro e o slot de pod (29 enderecos por no), e
  # nao cpu nem memoria. so na zona a porque volume EBS tem afinidade de zona, e o
  # broker e a busca tambem ficam la.
  eks_managed_node_groups = {
    nos = {
      instance_types = ["m7i-flex.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 2
      max_size       = 2
      desired_size   = 2
      subnet_ids     = [data.aws_subnet.publica["a"].id]
    }
  }
}
