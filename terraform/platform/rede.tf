# as zonas vem do provedor, e nao fixadas por letra: o mapeamento de letra para
# zona fisica varia por conta, e zona nomeada sem capacidade faria a primeira
# aplicacao falhar no lancamento da instancia.
data "aws_availability_zones" "disponiveis" {
  state = "available"

  # exclui zonas locais e de operadora, que nao servem a VPC Link nem ao broker
  # gerenciado.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "satelite" {
  cidr_block = "10.0.0.0/16"

  # nomes de dns habilitados porque o namespace de descoberta privado resolve
  # dentro da VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}vpc"
  }
}

resource "aws_internet_gateway" "satelite" {
  vpc_id = aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}igw"
  }
}

# duas sub-redes publicas, uma por zona: sao duas porque a VPC Link exige zonas
# distintas, nao por alta disponibilidade. publicas porque nao ha NAT gateway --
# ele cobraria 24/7 e a unica saida necessaria e a da propria instancia.
#
# o sufixo do nome e a letra local, e nao o nome da zona resolvida, para que
# quem procure estas sub-redes por etiqueta nao precise saber o que o provedor
# devolveu.
resource "aws_subnet" "publica" {
  for_each = {
    a = { indice = 0, cidr = "10.0.1.0/24" }
    b = { indice = 1, cidr = "10.0.2.0/24" }
  }

  vpc_id            = aws_vpc.satelite.id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.disponiveis.names[each.value.indice]

  # o endereco publico automatico e o que faz a instancia alcancar a internet no
  # primeiro boot, antes do endereco fixo ser associado; sem ele o dado de
  # inicializacao morre no download do instalador e a maquina sobe sem cluster.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}subrede-${each.key}"
  }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.satelite.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.satelite.id
  }

  tags = {
    Name = "${var.name_prefix}rotas-publicas"
  }
}

# sem a associacao a sub-rede cai na tabela principal da VPC, que nao tem rota de
# saida: mesma falha silenciosa do endereco publico automatico.
resource "aws_route_table_association" "publica" {
  for_each = aws_subnet.publica

  subnet_id      = each.value.id
  route_table_id = aws_route_table.publica.id
}
