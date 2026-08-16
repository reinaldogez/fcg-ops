# fcg-ops — orquestração da plataforma FCG

Repositório de **orquestração** da FIAP Cloud Games (FCG): reúne a infraestrutura compartilhada
(RabbitMQ + stack de observabilidade LGTM + OTel Collector) e os artefatos de deploy
(`docker-compose.yml` e manifestos Kubernetes) dos microsserviços. Não contém código de
aplicação — só composição, configuração e orquestração.

A plataforma é **orientada a eventos**: os serviços se comunicam de forma assíncrona via
RabbitMQ em coreografia (sem orquestrador central), publicando e consumindo eventos de domínio.

A plataforma orquestra os quatro serviços — quatro **domínios**:
**`fcg-identity`** (identidade, autenticação, emissão de JWT), **`fcg-catalog`** (catálogo de
jogos, pedidos e biblioteca), **`fcg-payments`** (processamento de pagamento) e
**`fcg-notifications`** (consome eventos e dispara notificações). O primeiro **fluxo
cross-service** fecha em coreografia: o identity **publica** `UserCreatedEvent` e o
notifications **consome**, enviando o e-mail de boas-vindas. O catalog traz a primeira
**integração de autenticação entre serviços** (valida os JWT emitidos pelo identity) e, com o
payments, a **saga de compra** fecha de ponta a ponta: pedido → pagamento → biblioteca +
notificação, tudo por eventos. Não há serviços pendentes de orquestração — os quatro rodam
em Compose e em Kubernetes.

---

## Subir localmente

O passo a passo completo — pré-requisitos, os dois fluxos de Docker Compose, o cluster
Kubernetes em k3d, a materialização dos arquivos não-versionados, o acesso por encaminhamento
de porta e o diagnóstico — está em **[docs/ambiente-local.md](docs/ambiente-local.md)**, que
também traz os diagramas de topologia (fluxo de negócio e telemetria).

Em forma curta, o caminho mais rápido é o Compose:

```bash
cp .env.example .env                                   # preencha os valores reais
bash scripts/gen-rsa-key.sh                            # gera o par de chaves RSA
cp docker-compose.override.example.yml docker-compose.override.yml   # cole o PEM nele
docker compose up -d
```

E o cluster local:

```bash
bash scripts/bootstrap-k3d.sh     # cria o cluster k3d 'fcg'
cp .env.example .env.k3d          # preencha os valores reais
bash scripts/init-secrets.sh      # materializa Secrets e ConfigMaps fora do git
bash scripts/apply-all.sh         # aplica os manifestos em ordem de boot
```

---

## Notas de arquitetura

### Manifestos centralizados (em vez de `/k8s` por serviço)

A convenção usual coloca uma pasta `/k8s` na raiz de cada repositório de serviço. Aqui os manifestos
estão **centralizados** em `fcg-ops/k8s/`. Não é um conflito: `/k8s` por serviço é o **caso
base** — garante que cada serviço seja deployável isoladamente. O repositório de orquestração é
a **camada de orquestração — um cenário opcional dessa convenção**; ao adotá-lo, estamos no caso "com
orquestração", onde a visão única do sistema (e o `kubectl apply` de um único lugar) vive aqui.
Cada serviço continua deployável por si — sua imagem vem do GHCR, independente de onde o YAML mora.

### Escolha de controller por tipo de carga

Cada workload usa o controller que melhor casa com seu ciclo de vida. Nenhum recurso é um `Pod`
avulso — todo Pod nasce sob um controller que cuida de recriação, ordem e escala:

| Carga | Controller | Por quê | Serviços |
|---|---|---|---|
| Com estado | **StatefulSet + PVC** | identidade de rede estável e volume persistente por pod | `sqlserver-identity`, `postgres-catalog`, `postgres-payments`, `rabbitmq` |
| Sem estado | **Deployment** | réplicas intercambiáveis; estado descartável | `identity-api`, `catalog-api`, `payments-api`, `notifications-api`, `redis`, Loki/Tempo/Prometheus/Grafana, OTel Collector |
| Tarefa única | **Job** | roda uma vez até concluir e encerra | `identity-migrate` (migrations), `catalog-migrate` (migrations + seed do catálogo), `payments-migrate` (migrations, sem seed) |

Assim os bancos e o broker preservam dados entre reinícios (StatefulSet), as aplicações escalam
e se recuperam sozinhas (Deployment), e as migrations executam uma vez e saem (Job) — cada Pod
sob o controller correto para o seu papel. O `postgres-catalog` e o `postgres-payments` seguem
o mesmo raciocínio do `sqlserver-identity`: banco relacional cujo estado importa →
StatefulSet + PVC.

O `redis` aparece na linha **Deployment** (não StatefulSet) de propósito: ele guarda **só a
idempotência descartável** do notifications — a chave `notifications:processed:{MessageId}` com
TTL de 24h, sobre `emptyDir`. Perder esse estado num restart não corrompe nada: o pior caso é
reprocessar uma mensagem dentro da janela (e-mail duplicado), nunca dado inconsistente. Por isso
não precisa de identidade de rede estável nem de volume persistente — o controller stateless basta.

---

## Estrutura do repositório

```
fcg-ops/
├── docker-compose.yml                     # stack local completa (infra + observabilidade + identity + notifications + catalog + payments)
├── docker-compose.override.example.yml    # template do override de chave RSA (placeholder)
├── .env.example                           # template das variáveis (placeholders); copie para .env.k3d / .env.ec2
├── scripts/
│   ├── gen-rsa-key.sh                      # gera o par de chaves RSA
│   ├── bootstrap-k3d.sh                    # cria o cluster k3d 'fcg'
│   ├── init-secrets.sh                     # materializa os Secrets reais a partir do arquivo do perfil
│   └── apply-all.sh                        # aplica os manifestos em ordem de boot
├── observability/                          # configs canônicas (Loki, Tempo, Prometheus, Grafana, OTel)
└── k8s/
    ├── 00-namespace.yaml
    ├── 01-infra/                           # sqlserver-identity, postgres-catalog, postgres-payments, rabbitmq (StatefulSet + PVC), redis (Deployment + emptyDir)
    │   ├── postgres-catalog/               # statefulset, service (headless), secret(s)
    │   ├── postgres-payments/              # statefulset, service (headless), secret(s)
    │   └── redis/                          # deployment, service, secret(s)
    ├── 02-observability/                   # loki, tempo, prometheus, grafana, otel-collector
    └── 03-services/                        # apps stateless
        ├── catalog/                        # configmap, secret(s), migrate-job (migrate+seed), deployment, service
        ├── identity/                       # configmap, secret(s), migrate-job, deployment, service
        ├── notifications/                  # configmap, secret(s), deployment, service (consumer-only, sem migrate-job)
        └── payments/                       # configmap, secret(s), migrate-job (só migrate), deployment, service (consumer-only)
```

---
