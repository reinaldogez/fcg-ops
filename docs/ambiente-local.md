# Ambiente local — Docker Compose e Kubernetes (k3d)

Guia de execução da plataforma FCG na máquina do desenvolvedor. Cobre os dois alvos locais:
**Docker Compose** (mais rápido, sem cluster) e **Kubernetes em k3d** (fiel ao alvo de nuvem).

Os dois sobem o mesmo conjunto de serviços — `fcg-identity`, `fcg-catalog`, `fcg-payments` —
com a infraestrutura compartilhada (SQL Server, PostgreSQL, RabbitMQ, Redis, emulador do read
model) e a stack de observabilidade (Loki, Tempo, Prometheus, Grafana, OTel Collector).

> **Nenhum dos dois fluxos usa credencial de nuvem.** Tudo aqui roda offline, contra imagens
> públicas e serviços locais.

---

## Sumário

- [Pré-requisitos](#pré-requisitos)
- [Conceito: o que não é versionado](#conceito-o-que-não-é-versionado)
- [Fluxo 1 — Docker Compose](#fluxo-1--docker-compose)
- [Fluxo 2 — Kubernetes em k3d](#fluxo-2--kubernetes-em-k3d)
- [Acesso aos serviços](#acesso-aos-serviços)
- [Verificação de ponta a ponta](#verificação-de-ponta-a-ponta)
- [Observabilidade](#observabilidade)
- [Operações sob demanda](#operações-sob-demanda)
- [Diagnóstico](#diagnóstico)
- [Encerrar o ambiente](#encerrar-o-ambiente)
- [Topologia](#topologia)

---

## Pré-requisitos

| Ferramenta | Para quê | Como instalar (Windows) |
|---|---|---|
| **Docker Desktop** | Roda os containers do Compose e dá o backend ao cluster k3d. Traz o Compose v2 (`docker compose`). | <https://www.docker.com/products/docker-desktop/> |
| **kubectl** | Aplica os manifestos de `k8s/`. | Já vem com o Docker Desktop. |
| **k3d** | Sobe o cluster Kubernetes local (k3s em Docker). | `winget install --id k3d.k3d -e --source winget` |
| **OpenSSL** | Gera o par de chaves RSA de assinatura do JWT. | Já vem com o Git para Windows. |
| **PAT do GitHub** com `read:packages` | **Só** para o fluxo `docker compose up --build`. O fluxo padrão não precisa. | <https://github.com/settings/tokens> |

Depois de instalar o k3d, **reabra o terminal** para o PATH atualizar e confirme com
`k3d version`.

Os scripts deste repositório são `bash`. No Windows, rode-os pelo **Git Bash** ou por
`bash scripts/<nome>.sh` a partir de um terminal que tenha o bash do Git no PATH.

---

## Conceito: o que não é versionado

Nenhum valor real de senha, connection string ou chave privada entra no git. O repositório
carrega apenas **templates com placeholder**; o valor real é materializado localmente.

| Arquivo versionado (template) | Arquivo local gerado (fora do git) | Conteúdo |
|---|---|---|
| `.env.example` | `.env`, `.env.k3d`, `.env.ec2` | Senhas, connection strings e a configuração que varia por ambiente |
| `docker-compose.override.example.yml` | `docker-compose.override.yml` | A chave RSA privada, como block scalar |
| `secret.example.yaml` (vários) | `secret.yaml`, `secret-jwt.yaml` | Os dez Secrets do cluster |
| `configmap-env.example.yaml` (três) | `configmap-env.yaml` | O que difere entre o cluster local e o da nuvem |

### Perfis de ambiente

O ambiente é selecionado por `FCG_PERFIL`, que aceita **`k3d`** (padrão) ou **`ec2`**. Cada
perfil tem seu próprio arquivo de valores — `.env.k3d` e `.env.ec2` — porque host, porta e TLS
do broker diferem: no cluster local o RabbitMQ atende `5672` em texto claro; na nuvem o broker
gerenciado atende `5671` com TLS.

Manter um arquivo só obrigaria a editar essas chaves a cada troca de ambiente, e o esquecimento
**não dá erro de configuração** — dá conexão que falha longe da causa.

Na ausência do arquivo do perfil, os scripts recuam para `.env`. Um `ENV_FILE` explícito vence
o perfil.

> **Gere os arquivos de perfil a partir do `.env.example`, nunca copiando um `.env` de sessão
> anterior.** O `.example` é a única fonte de verdade da forma; cópias antigas arrastam chaves
> que já saíram do repositório.

### As seis variáveis que variam por ambiente

Estas não são credencial, mas mudam entre o cluster local e o da nuvem. Por isso ficam fora do
ConfigMap versionado: o `init-secrets.sh` lê o arquivo do perfil e gera os `configmap-env.yaml`.

| Variável no arquivo de perfil | Chave gerada | Valor no `k3d` |
|---|---|---|
| `RABBITMQ_HOST` | `RabbitMq__Host` | `rabbitmq` |
| `RABBITMQ_PORT` | `RabbitMq__Port` | `5672` |
| `RABBITMQ_USE_SSL` | `RabbitMq__UseSsl` | `false` |
| `JWT_ISSUER` | `Jwt__Issuer` | `fcg-identity` |
| `JWT_PUBLIC_BASE_URL` | `Jwt__PublicBaseUrl` | *(vazio)* |
| `DYNAMODB_SERVICE_URL` | `DynamoDb__ServiceUrl` | `http://dynamodb-local:8000` |

Duas delas são legitimamente vazias em um dos ambientes (`JWT_PUBLIC_BASE_URL` no `k3d`,
`DYNAMODB_SERVICE_URL` na nuvem). Para essas a exigência é a **chave estar declarada** no
arquivo, não ter valor — assim um nome digitado errado ainda falha, em vez de virar string
vazia em silêncio.

No `.env.example`, o valor do perfil `ec2` vem numa linha `# ec2:` logo acima de cada variável.
**Nunca ponha comentário na mesma linha da variável**: a leitura pega tudo após o `=` como
valor e engoliria o comentário junto.

---

## Fluxo 1 — Docker Compose

O caminho mais curto. Sobe tudo em containers, sem cluster.

### Passo 1 — arquivo de variáveis

```bash
cp .env.example .env
```

Preencha os valores reais. O Compose lê o `.env` diretamente (não o `.env.k3d`), porque a
interpolação `${VAR}` do Compose usa o `.env` do diretório corrente.

### Passo 2 — chave RSA de assinatura

```bash
bash scripts/gen-rsa-key.sh
```

Gera `identity-rsa-private.pem` e `identity-rsa-public.pem` na raiz. O script **não sobrescreve**
chave existente — se já houver uma, ele avisa e sai.

### Passo 3 — a chave no override

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
```

Edite `docker-compose.override.yml` e cole o conteúdo de `identity-rsa-private.pem` no block
scalar `Jwt__RsaPrivateKeyPem`, no lugar do `REPLACE_ME`. Cole o PEM **inteiro**, incluindo as
linhas `-----BEGIN PRIVATE KEY-----` e `-----END PRIVATE KEY-----`, indentado em 4 espaços.

A chave vai no override e não no `.env` porque um PEM é multilinha e quebra o parsing do `.env`.
O override usa uma âncora YAML para injetar a mesma chave nos dois serviços que precisam dela
(`identity-migrate` e `identity-api`), e é carregado automaticamente junto do
`docker-compose.yml`.

### Passo 4a — subir puxando as imagens (padrão, sem token)

```bash
docker compose up -d
```

Puxa as imagens já publicadas em `ghcr.io/reinaldogez/fcg-*:latest`. É o caminho recomendado.

### Passo 4b — subir compilando (desenvolvimento)

Compila as imagens a partir dos repositórios irmãos, que precisam estar clonados **ao lado**
deste (`../fcg-identity`, `../fcg-catalog`, `../fcg-payments`).

O build faz `dotnet restore` do pacote `Fcg.Contracts` no feed NuGet do GitHub Packages, que
**exige autenticação mesmo para pacote público** — diferente do registro de imagens, que serve
anonimamente. Por isso o build precisa de um token:

```bash
export GH_TOKEN=<PAT com read:packages>   # vale so na sessao atual do shell
docker compose up -d --build
```

O token é injetado como **secret de build**: vive apenas na camada de build, é usado só no
`restore` e **não persiste na imagem final**. O repositório guarda apenas o ponteiro do secret
(a variável de ambiente `GH_TOKEN`); o valor real nunca entra no git.

Para não redigitar o token a cada terminal, grave-o no escopo do usuário no Windows:

```powershell
[Environment]::SetEnvironmentVariable("GH_TOKEN", "<PAT com read:packages>", "User")
```

O efeito só aparece em terminais **abertos depois** do comando. Confira com:

```powershell
[Environment]::GetEnvironmentVariable("GH_TOKEN", "User")
```

### Passo 5 — esperar a convergência

O `docker compose up` já respeita a ordem de dependência: os bancos ficam `healthy` antes das
migrations rodarem, e as APIs só sobem depois que a migration correspondente sai com sucesso.

```bash
docker compose ps -a
```

O estado esperado é **três containers `Exited (0)`** — as migrations, que rodam uma vez e
encerram — e o **restante `Up`**, com os de infraestrutura marcados `(healthy)`.

O primeiro boot leva mais tempo por causa do SQL Server, que só aceita conexão depois de
sair do recovery.

---

## Fluxo 2 — Kubernetes em k3d

Fiel ao alvo de nuvem: os mesmos manifestos que rodam no cluster da instância.

### Passo 1 — criar o cluster

```bash
bash scripts/bootstrap-k3d.sh
```

Cria o cluster k3d chamado `fcg` e confirma que o `kubectl` aponta para ele. É idempotente: se
o cluster já existir, avisa e não recria. Para começar do zero:

```bash
k3d cluster delete fcg && bash scripts/bootstrap-k3d.sh
```

> O cluster é criado **sem publicar portas no host**. O acesso aos serviços é por
> `kubectl port-forward` — ver [Acesso aos serviços](#acesso-aos-serviços).

### Passo 2 — arquivo de variáveis do perfil

```bash
cp .env.example .env.k3d
```

Preencha os valores reais, usando os valores de `k3d` da
[tabela das seis variáveis](#as-seis-variáveis-que-variam-por-ambiente).

### Passo 3 — materializar Secrets e ConfigMaps

```bash
bash scripts/init-secrets.sh
```

O script lê o arquivo do perfil, gera (ou reaproveita) a chave RSA e escreve **dez Secrets** e
**três ConfigMaps de ambiente**, todos fora do versionamento:

| Secrets gerados | ConfigMaps gerados |
|---|---|
| `k8s/01-infra/sqlserver-identity/secret.yaml` | `k8s/03-services/identity/configmap-env.yaml` |
| `k8s/01-infra/rabbitmq/secret.yaml` | `k8s/03-services/catalog/configmap-env.yaml` |
| `k8s/01-infra/redis/secret.yaml` | `k8s/03-services/payments/configmap-env.yaml` |
| `k8s/01-infra/postgres-catalog/secret.yaml` | |
| `k8s/01-infra/postgres-payments/secret.yaml` | |
| `k8s/02-observability/grafana/secret.yaml` | |
| `k8s/03-services/identity/secret.yaml` | |
| `k8s/03-services/identity/secret-jwt.yaml` | |
| `k8s/03-services/catalog/secret.yaml` | |
| `k8s/03-services/payments/secret.yaml` | |

O script é idempotente: reexecutar regenera os arquivos a partir do arquivo de perfil atual, e
a chave RSA existente é reaproveitada. Ele **não inventa valores** — só materializa o que você
preencheu.

Para o perfil de nuvem, o mesmo script com o perfil trocado:

```bash
FCG_PERFIL=ec2 bash scripts/init-secrets.sh
```

<details>
<summary>Alternativa manual, sem o script</summary>

Copie cada template e preencha os placeholders à mão:

```bash
cp k8s/01-infra/sqlserver-identity/secret.example.yaml k8s/01-infra/sqlserver-identity/secret.yaml
cp k8s/01-infra/rabbitmq/secret.example.yaml           k8s/01-infra/rabbitmq/secret.yaml
cp k8s/01-infra/redis/secret.example.yaml              k8s/01-infra/redis/secret.yaml
cp k8s/01-infra/postgres-catalog/secret.example.yaml   k8s/01-infra/postgres-catalog/secret.yaml
cp k8s/01-infra/postgres-payments/secret.example.yaml  k8s/01-infra/postgres-payments/secret.yaml
cp k8s/02-observability/grafana/secret.example.yaml    k8s/02-observability/grafana/secret.yaml
cp k8s/03-services/identity/secret.example.yaml        k8s/03-services/identity/secret.yaml
cp k8s/03-services/identity/secret-jwt.example.yaml    k8s/03-services/identity/secret-jwt.yaml
cp k8s/03-services/catalog/secret.example.yaml         k8s/03-services/catalog/secret.yaml
cp k8s/03-services/payments/secret.example.yaml        k8s/03-services/payments/secret.yaml
cp k8s/03-services/identity/configmap-env.example.yaml k8s/03-services/identity/configmap-env.yaml
cp k8s/03-services/catalog/configmap-env.example.yaml  k8s/03-services/catalog/configmap-env.yaml
cp k8s/03-services/payments/configmap-env.example.yaml k8s/03-services/payments/configmap-env.yaml
```

Depois edite cada arquivo e substitua os placeholders pelos valores reais. No `secret-jwt.yaml`,
cole o PEM gerado por `scripts/gen-rsa-key.sh` no block scalar.

Para a chave, há um caminho sem editar YAML:

```bash
kubectl create secret generic identity-jwt -n fcg \
  --from-file=Jwt__RsaPrivateKeyPem=identity-rsa-private.pem \
  --from-literal=Jwt__KeyId=fcg-identity-key-1
```

</details>

### Passo 4 — aplicar os manifestos

```bash
bash scripts/apply-all.sh
```

O script aplica em ordem de boot e espera cada fase:

1. **namespace**;
2. **infraestrutura**, com `kubectl wait` até os pods ficarem `Ready`;
3. **observabilidade**, gerando os ConfigMaps do Grafana a partir dos diretórios-fonte;
4. **serviços**, esperando cada Job de migration concluir antes de subir o Deployment
   correspondente.

Antes de aplicar qualquer coisa, ele confere que os treze arquivos gerados no passo 3 existem —
se faltar algum, falha nomeando o arquivo e explicando como resolver, sem ter tocado no cluster.

O perfil também vale aqui, e decide **o que sobe** da camada de infraestrutura:

```bash
FCG_PERFIL=ec2 bash scripts/apply-all.sh
```

No perfil `ec2`, `rabbitmq` e `dynamodb-local` **não sobem** — na nuvem os dois são serviço
gerenciado. Um broker local de pé numa sessão de nuvem seria um destino alternativo silencioso:
configuração errada conectaria nele e tudo pareceria funcionar, contra um broker vazio.

> **Num cluster recém-criado, o `apply-all.sh` leva cerca de 15 minutos**, dos quais ~7 são só o
> SQL Server ficando pronto. As migrations em série somam ~4 minutos e a observabilidade ~2.

### Passo 5 — confirmar que os serviços subiram

**O `apply-all.sh` espera os bancos e os Jobs de migration, mas não espera a prontidão dos três
serviços.** Ele termina reportando sucesso com os pods das APIs ainda subindo — então a
verificação abaixo é passo do procedimento, não zelo extra:

```bash
kubectl wait --for=condition=ready pod -l app=identity-api -n fcg --timeout=300s
kubectl wait --for=condition=ready pod -l app=catalog-api  -n fcg --timeout=300s
kubectl wait --for=condition=ready pod -l app=payments-api -n fcg --timeout=300s
```

O panorama completo:

```bash
kubectl get pods -n fcg
kubectl get jobs -n fcg
```

O estado esperado é **todos os pods `Running` e `1/1`**, e os **três Jobs `Complete`**.

<details>
<summary>Aplicar com <code>kubectl</code> puro, sem o script</summary>

```bash
kubectl apply -f ./k8s/ -R
```

O `-R` percorre as subpastas, e o prefixo numérico de topo (`00-`, `01-`, …) faz a ordem
alfabética coincidir com a ordem de dependência. Mesmo que algum recurso seja aplicado antes da
sua dependência, o cluster converge: cada pod traz um init container que o segura até o banco
responder.

**Duas ressalvas que este caminho carrega, e o `apply-all.sh` não:**

- **O `-R` aplica também os treze arquivos `*.example.yaml`**, que carregam placeholders. Os
  Secrets reais só prevalecem porque `secret.example.yaml` vem **antes** de `secret.yaml` na
  ordem alfabética, e o segundo sobrescreve o primeiro. É coincidência de ordenação, não
  desenho — o `apply-all.sh` filtra os templates explicitamente.
- **O Job de migration não é esperado.** Sem a ordem que o script impõe, o `identity-api` sobe
  antes do banco ter schema, reinicia algumas vezes e só então converge. Não é sintoma de
  defeito, mas polui o diagnóstico.

Prefira o `apply-all.sh` para um boot limpo e ordenado.

</details>

---

## Acesso aos serviços

### No Compose

As portas são publicadas direto no host:

| Serviço | Endereço | Observação |
|---|---|---|
| `identity-api` | <http://localhost:8081> | REST de identidade e autenticação |
| `catalog-api` | <http://localhost:8083> | REST de catálogo, pedidos e biblioteca |
| `payments-api` | <http://localhost:8084> | Só health — worker sem REST de negócio |
| RabbitMQ (UI) | <http://localhost:15672> | Credenciais em `RABBITMQ_USER` / `RABBITMQ_PASSWORD` |
| Grafana | <http://localhost:3000> | Ver [Observabilidade](#observabilidade) |

### No k3d

O cluster é criado sem publicar portas, então o acesso é por encaminhamento de porta:

```bash
kubectl port-forward svc/identity-api 8081:80    -n fcg   # http://localhost:8081
kubectl port-forward svc/catalog-api  8083:80    -n fcg   # http://localhost:8083
kubectl port-forward svc/payments-api 8084:80    -n fcg   # http://localhost:8084
kubectl port-forward svc/grafana      3000:3000  -n fcg   # http://localhost:3000
kubectl port-forward svc/rabbitmq     15672:15672 -n fcg  # http://localhost:15672
```

Cada comando ocupa o terminal enquanto o encaminhamento estiver ativo.

> **Não rode o Compose e os encaminhamentos do k3d ao mesmo tempo nas mesmas portas.** Os dois
> alvos usam 8081, 8083, 8084, 3000 e 15672. Com ambos de pé, quem chegar primeiro fica com a
> porta e o outro falha — ou, pior, o encaminhamento responde e dá a impressão de que o Compose
> está saudável quando o container sequer subiu. Se precisar dos dois, use portas distintas
> (`kubectl port-forward svc/identity-api 9081:80 -n fcg`).

#### Sobre as portas de nó

Os Services `identity-api` e `catalog-api` declaram `type: NodePort` com as portas **30081** e
**30083**, fixadas para o alvo de nuvem, onde o gateway alcança o cluster por elas.

**No k3d essas portas não são alcançáveis do host.** O `bootstrap-k3d.sh` cria o cluster sem
mapear portas, então só a porta da API do Kubernetes é publicada — `curl localhost:30081` não
responde. Localmente, o encaminhamento de porta é o caminho.

---

## Verificação de ponta a ponta

Os comandos abaixo valem nos dois fluxos, desde que os endereços estejam acessíveis. Substitua
as portas se estiver usando outras.

### 1. Health dos três serviços

```bash
curl -s -o /dev/null -w "identity: %{http_code}\n" http://localhost:8081/health/ready
curl -s -o /dev/null -w "catalog:  %{http_code}\n" http://localhost:8083/health/ready
curl -s -o /dev/null -w "payments: %{http_code}\n" http://localhost:8084/health/ready
```

Os três respondem `200`.

### 2. Cadastro de usuário

```bash
curl -i -X POST http://localhost:8081/api/usuarios \
  -H 'Content-Type: application/json' \
  -d '{"nome":"Exemplo","email":"exemplo@fcg.local","senha":"Exemplo@123456"}'
```

Resposta `201`. O evento de usuário criado é publicado no broker.

### 3. Login

```bash
curl -s -X POST http://localhost:8081/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"exemplo@fcg.local","senha":"Exemplo@123456"}'
```

Devolve o token e o identificador do usuário. Guarde os dois: o token vai no cabeçalho
`Authorization: Bearer <token>` das chamadas ao catálogo, e o identificador entra na consulta
à biblioteca.

A conta administrativa é semeada no boot com a senha de `ADMINSEED_PASSWORD`.

### 4. Autenticação entre serviços

```bash
curl -s http://localhost:8083/api/jogos                          # 401 sem token
curl -s http://localhost:8083/api/jogos -H "Authorization: Bearer <token>"   # 200
```

O `401` sem token e o `200` com token provam a integração: o catálogo valida, contra o conjunto
de chaves públicas servido pelo identity, um token que ele não emitiu.

O catálogo já vem com um seed de jogos, então a listagem devolve conteúdo num cluster novo.

### 5. Saga de compra

```bash
curl -s -X POST http://localhost:8083/api/pedidos \
  -H "Authorization: Bearer <token>" -H 'Content-Type: application/json' \
  -d '{"jogoId":"<id de um jogo>"}'
```

Devolve `202` com o pedido em `Pendente`. Alguns segundos depois:

```bash
curl -s http://localhost:8083/api/pedidos/<id do pedido> -H "Authorization: Bearer <token>"
curl -s http://localhost:8083/api/biblioteca/<id do usuario> -H "Authorization: Bearer <token>"
```

O pedido está `Aprovado` e o jogo aparece na biblioteca. O caminho percorrido é inteiramente
por eventos: o catálogo publica o pedido, o payments consome e decide, publica de volta o
resultado, e o catálogo credita a biblioteca no read model.

**Rejeição:** pedidos acima do teto de `Payment__RejectionThreshold` (padrão `5000`) são
recusados. O pedido fica `Rejeitado` com o motivo preenchido, e a biblioteca **não** muda.
O seed não traz jogo acima do teto — crie um com a conta administrativa para exercitar o
caminho.

### 6. Estado do broker

Na interface do RabbitMQ (<http://localhost:15672>), em **Queues**, três filas aparecem com
`consumers = 1` e sem mensagens acumuladas:

- `order-placed.fcg-payments`
- `payment-processed.fcg-catalog`
- `payment-processed.fcg-catalog-projections`

> **A perna de notificação não existe no ambiente local, e isso é esperado.** As exchanges
> `user-created` e `payment-processed` registram publicação sem consumidor do lado das
> notificações, porque esse consumidor é uma função serverless que só existe na nuvem. A perna
> está truncada por ambiente, não por defeito.

---

## Observabilidade

O Grafana responde em <http://localhost:3000>, com três fontes de dados provisionadas no boot —
Loki (logs), Tempo (traces) e Prometheus (métricas) — e um dashboard já carregado, **FCG — visão
geral**, em *Dashboards*. Nada precisa ser importado à mão.

O dashboard vive em `observability/grafana/provisioning/dashboards/fcg-visao-geral.json` e é a
mesma fonte nos dois alvos: o Compose monta o diretório, e o `apply-all.sh` gera o ConfigMap a
partir dele. Uma cópia só, sem divergência entre os mundos.

Os cinco painéis cobrem latência, volume de requisições, distribuição por código de status e
taxa de erro, com o seletor de serviço no topo.

**O que o dashboard mede é o servidor.** As respostas que o serviço nunca chega a ver não
aparecem nele — num ambiente com gateway à frente, o que é barrado na borda não incrementa a
métrica. Localmente não há borda, então o painel vê tudo que chega às APIs.

O painel de 4xx frequentemente aparece vazio, e isso não é defeito: sob janela móvel de cinco
minutos, sem 4xx recente não há série para desenhar.

### Credenciais do Grafana

**No k3d**, o usuário e a senha vêm de `GRAFANA_ADMIN_USER` e `GRAFANA_ADMIN_PASSWORD` do
arquivo de perfil, materializados no Secret `grafana-secret` pelo `init-secrets.sh`.

**No Compose**, o serviço do Grafana não recebe credencial: vale o padrão embutido da imagem
(`admin` / `admin`), que a interface pede para trocar no primeiro acesso. Trocar as variáveis do
`.env` **não** muda o login do Grafana no Compose — só no k3d.

---

## Operações sob demanda

### Reconstruir o read model da biblioteca

O read model da biblioteca vive no emulador do DynamoDB, que roda **em memória e sem volume** —
os dados são reconstruíveis a partir do banco relacional, então perdê-los não corrompe nada.
Apagar o pod do emulador esvazia a biblioteca.

Para reconstruí-la a partir do relacional, sem apagar nada:

```bash
kubectl apply -f k8s/03-services/catalog/reprojetar-job.yaml
kubectl wait --for=condition=complete job/catalog-reprojetar -n fcg --timeout=300s
```

Ao concluir, o log do Job informa quantos itens foram projetados:

```bash
kubectl logs job/catalog-reprojetar -n fcg
```

O Job **não** faz parte da subida automática, de propósito: é operação sob demanda. Para
reexecutá-lo, apague o Job anterior antes (`kubectl delete job catalog-reprojetar -n fcg`) — um
Job concluído não roda de novo.

> **A tabela precisa existir antes de o Job rodar.** Quem cria a tabela `fcg-biblioteca` é o
> **boot do `catalog-api`**, não o Job de reconstrução. Se o pod do emulador foi apagado, a
> tabela se foi junto com ele (a execução é em memória), e o Job falha com
> `Cannot do operations on a non-existent table` — estourando o limite de tentativas e apagando
> o próprio pod, o que deixa o diagnóstico sem log à mão. A ordem correta depois de perder o
> emulador é reiniciar o catálogo primeiro, e só então reconstruir:
>
> ```bash
> kubectl rollout restart deployment/catalog-api -n fcg
> kubectl rollout status  deployment/catalog-api -n fcg --timeout=300s
> kubectl apply -f k8s/03-services/catalog/reprojetar-job.yaml
> ```

### Reexecutar uma migration

Os Jobs de migration rodam uma vez. Para reexecutar:

```bash
kubectl delete job identity-migrate -n fcg
kubectl apply -f k8s/03-services/identity/migrate-job.yaml
```

O mesmo vale para `catalog-migrate` (que também semeia o catálogo) e `payments-migrate`.

---

## Diagnóstico

### Ver logs

```bash
docker compose logs -f identity-api          # Compose
kubectl logs -f -l app=identity-api -n fcg   # k3d
```

### Um pod não sai de `Init`

Cada serviço tem um init container que espera o banco responder. Pod parado em `Init:0/1`
significa que o banco correspondente ainda não está pronto:

```bash
kubectl get pods -n fcg
kubectl describe pod <nome do pod> -n fcg
```

Num cluster novo, o SQL Server leva vários minutos. Se passar disso, confira se o Secret com a
senha foi materializado e se o pod do banco está `Running`.

### O identity reinicia algumas vezes ao subir

Se os Deployments foram aplicados sem o Job de migration ter concluído — o que acontece no
caminho do `kubectl apply -R` —, o identity encontra um banco sem schema e reinicia até a
migration rodar. Pela via do `apply-all.sh` isso não ocorre: ele ordena migration antes do
Deployment.

### Os serviços reclamam do broker no log

Os serviços toleram o broker ausente no boot: ficam `Running` e reconectam sozinhos quando ele
aparece, sem reinício. Um log com erro de conexão ao broker enquanto ele ainda sobe é ruído
esperado, não falha — o serviço fica saudável e o laço de retentativa cessa na conexão.

### `docker compose exec` reclama de caminho no Windows

No Git Bash, caminhos absolutos dentro do container são reescritos para caminhos do Windows
antes de chegar ao Docker, e o comando falha dizendo que o executável não existe. Desative a
conversão na chamada:

```bash
MSYS_NO_PATHCONV=1 docker compose exec sqlserver-identity /opt/mssql-tools18/bin/sqlcmd ...
```

### O RabbitMQ não sobe e o log fala do arquivo de cookie

Se o log do RabbitMQ terminar em `Error when reading /var/lib/rabbitmq/.erlang.cookie: eacces`,
o volume tem um arquivo de cookie com dono e permissão que o processo do broker não consegue
ler. O volume é descartável — o broker recria a topologia no boot dos serviços:

```bash
docker compose down
docker volume rm fcg_rabbitmq-data
docker compose up -d
```

### Recomeçar do zero

```bash
docker compose down -v          # Compose, incluindo os volumes de dados
k3d cluster delete fcg          # k3d, cluster inteiro
```

Nos dois casos, os dados de banco são descartados e as migrations rodam de novo na próxima
subida.

---

## Encerrar o ambiente

```bash
docker compose down             # para os containers, preserva os volumes
docker compose down -v          # para os containers e apaga os dados
```

```bash
k3d cluster stop fcg            # para o cluster, preserva o estado
k3d cluster start fcg           # retoma
k3d cluster delete fcg          # remove o cluster inteiro
```

Encaminhamentos de porta são processos: encerram com `Ctrl+C` no terminal que os iniciou, ou
matando o processo `kubectl` correspondente. **Encaminhamento esquecido é fonte recorrente de
diagnóstico errado** — ele continua respondendo na porta depois que o cluster mudou.

---

## Topologia

### Fluxo de negócio

> **Estado da Fase 2**, mantido aqui como marco de evolução do sistema. Retrata os quatro
> serviços em coreografia quando o `notifications` ainda era um serviço in-cluster. Na Fase 3
> ele foi descontinuado e sucedido por uma função serverless em repositório próprio, que **não
> sobe nem no Compose nem no k3d** — por isso a perna de notificação dos diagramas abaixo não
> tem correspondente no ambiente local.

```mermaid
flowchart LR
  client([cliente / curl]) -->|POST /api/usuarios| api[identity-api]
  client -->|POST /api/jogos · /api/pedidos| cat[catalog-api]

  api --> sql[(SQL Server<br/>sqlserver-identity)]
  api -->|UserCreatedEvent| mq[(RabbitMQ)]

  cat --> pg[(PostgreSQL<br/>postgres-catalog)]
  cat -.->|valida JWT · JWKS| api
  cat -->|OrderPlacedEvent| mq

  mq -->|order-placed.fcg-payments| pay[payments-api]
  pay --> pgp[(PostgreSQL<br/>postgres-payments)]
  pay -->|PaymentProcessedEvent| mq

  mq -->|payment-processed.fcg-catalog| cat
  mq -->|user-created.fcg-notifications| notif[notifications-api]
  mq -->|payment-processed.fcg-notifications| notif
  notif --> redis[(Redis<br/>idempotência)]
```

### Telemetria

Os quatro serviços emitem os mesmos sinais pelos mesmos caminhos — logs por push direto no
Loki, traces e métricas por OTLP no Collector:

```mermaid
flowchart LR
  api[identity-api] -->|logs · push| loki[(Loki)]
  cat[catalog-api] -->|logs · push| loki
  pay[payments-api] -->|logs · push| loki
  notif[notifications-api] -->|logs · push| loki

  api -->|OTLP gRPC :4317| col[OTel Collector]
  cat -->|OTLP gRPC :4317| col
  pay -->|OTLP gRPC :4317| col
  notif -->|OTLP gRPC :4317| col

  col -->|traces| tempo[(Tempo)]
  col -->|/metrics :8889| prom[(Prometheus)]

  loki --> graf[[Grafana]]
  tempo --> graf
  prom --> graf
```

- **Logs:** os quatro serviços fazem push direto no Loki (sink Serilog), cada um com seu label
  (`app=fcg-identity`, `app=fcg-notifications`, `app=fcg-catalog` e `app=fcg-payments`) — o
  agregado `{app=~"fcg-.*"}` varre os quatro.
- **Traces e métricas:** os quatro serviços exportam ambos pelo mesmo OTLP gRPC para o OTel
  Collector, que roteia **traces → Tempo** e expõe **métricas em `:8889`** para o Prometheus
  fazer scrape (o payments aparece como `Fcg.Payments.Api`, seu service name OTel).
- **Auth cross-service:** o `catalog-api` é **resource server** — valida os tokens emitidos
  pelo `identity-api` baixando o JWKS (`/.well-known/jwks.json`) direto do identity, sem OIDC
  discovery. Issuer `fcg-identity`, Audience `fcg`. É a primeira integração de autenticação
  entre serviços da plataforma: a aresta tracejada `catalog-api -.-> identity-api` do diagrama
  é dependência de **auth**, não de dados.
- **Saga de compra (completa):** `POST /api/pedidos` publica `OrderPlacedEvent` na exchange
  `order-placed` → o `payments-api` **consome** pela fila `order-placed.fcg-payments`, decide
  o pagamento pelo preço (aprova se ≤ `Payment:RejectionThreshold`, default `5000`; rejeita
  acima) e **publica** `PaymentProcessedEvent` na exchange `payment-processed` → o **catalog**
  consome (`payment-processed.fcg-catalog`: credita a biblioteca no aprovado; marca o pedido
  `Rejeitado` na recusa) e o **notifications** consome (`payment-processed.fcg-notifications`:
  e-mail de confirmação ou recusa). Coreografia pura — cada serviço reage a eventos, sem
  orquestrador central.
- **Fluxo cross-service:** a aresta `user-created` antes era publicada e **descartada** (fanout
  sem fila bound — não havia consumidor). Agora o `notifications-api` a **consome** pela fila
  `user-created.fcg-notifications`, dispara o e-mail de boas-vindas e grava no Redis a chave de
  idempotência (TTL 24h, evita reenvio em reentrega). É o primeiro fluxo cross-service em
  coreografia da plataforma.
- **UI única:** o Grafana lê os três backends, permitindo correlação clicável entre logs e
  traces — inclusive cruzando serviços, já que o contexto de trace propaga do publish ao
  consume pelo header da mensagem. Um pedido aprovado gera um **trace único atravessando a
  saga**: catalog (publish `order-placed`) → payments (consume → processa → publish
  `payment-processed`) → catalog (credita a biblioteca) + notifications (e-mail).
