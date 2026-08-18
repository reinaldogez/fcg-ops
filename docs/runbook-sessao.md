# Runbook de sessão de nuvem

Procedimento para abrir, usar e fechar uma sessão de nuvem da FCG. A plataforma permanente
já existe: este documento **não** a levanta do zero — para conta virgem, veja
[levantar-do-zero.md](levantar-do-zero.md).

O que fica de pé entre sessões custa ~US$5,60/mês. O que se liga por sessão custa por hora, e
o fechamento existe para que ele não sobreviva à noite.

Salvo indicação em contrário, os comandos rodam **na raiz do repositório**, no laptop. Os que
rodam na instância estão marcados como tal.

## Sumário

- [Os dois perfis](#os-dois-perfis)
- [A máquina de quem administra](#a-máquina-de-quem-administra)
- [As coordenadas da plataforma](#as-coordenadas-da-plataforma)
- [Antes de iniciar a instância](#antes-de-iniciar-a-instância)
- [Abertura](#abertura)
- [Sessão verde](#sessão-verde)
- [Acesso ao Grafana](#acesso-ao-grafana)
- [Fechamento](#fechamento)
- [Inventário permanente](#inventário-permanente)
- [Diagnóstico](#diagnóstico)

---

## Os dois perfis

| | **Borda** | **Saga** |
|---|---|---|
| Instância do cluster | sim | sim |
| Workloads (rotas, authorizer, discovery, dashboard, cache) | sim | sim |
| Broker gerenciado | não | sim |
| Topologia (exchange, fila, associação) | não | sim |
| Função serverless e mapeamento de origem | não | sim |
| Custo por hora | só a instância | instância + broker (~US$0,14/h) |
| Tempo de abertura | ~5 min | ~15 min (o broker domina) |

**Na dúvida, Borda.** Subir o broker depois custa doze minutos; esquecê-lo ligado custa a
noite. O perfil Borda cobre tudo que não é mensageria: autenticação, rotas protegidas,
discovery, catálogo, read model, cache e dashboard.

---

## A máquina de quem administra

Esta seção é sobre o computador de onde os comandos saem, não sobre a plataforma. Num Linux ou
macOS quase nada aqui se aplica; num Windows com o Git para Windows, tudo se aplica.

**O que precisa existir:** `terraform`, `aws`, `kubectl`, `ssh`, `scp`, `tar`, `git`, e um
Python com a suíte de testes se for rodá-la. A credencial da AWS é a do usuário de operação,
conferida com `aws sts get-caller-identity` antes de qualquer coisa.

### A conversão de caminho do MSYS, e o comando que mente

O `bash` que acompanha o Git para Windows roda sobre MSYS, que **reescreve todo argumento
começado por `/`** como caminho do Windows antes de entregá-lo a um executável nativo. O
`aws.exe` é nativo. O efeito:

```
/aws/lambda/fcg-notifications-fn   →   C:/Program Files/Git/aws/lambda/fcg-notifications-fn
```

Dois sintomas, e o segundo é o caro:

| Comando | O que acontece |
|---|---|
| `aws logs describe-log-streams --log-group-name /aws/...` | `InvalidParameterException` — reclama, e você percebe |
| `aws logs filter-log-events --log-group-name /aws/...` | **volta vazio, com `exit 0`** — parece que nada aconteceu |

O segundo já produziu um diagnóstico errado: log vazio lido como "a função nunca foi invocada",
contra **23 invocações** que a métrica do CloudWatch mostrava. Um comando que passa por não ter
feito nada é pior que um que falha.

**Conserto**, uma vez por terminal, antes de qualquer `aws` com argumento em `/`:

```bash
export MSYS2_ARG_CONV_EXCL='*'
```

Fora do MSYS a variável não tem efeito nenhum, então exportá-la sempre é seguro.

O `inventario-aws.sh` **já faz esse export sozinho**, no topo — mas isso protege só o que roda
dentro dele. Consulta avulsa na linha de comando continua desprotegida, e é onde o erro
aparece.

**Quando o resultado for "nada aconteceu", confirme por outro caminho** antes de concluir:
métrica do CloudWatch em vez de log, `describe-*` em vez de `filter-*`. Ausência de resultado e
falha silenciosa são indistinguíveis aqui.

### Duas medidas, não uma

Invocar o inventário exige o caminho explícito do interpretador **e** a variável — cada uma
resolve um problema diferente, e cada uma sozinha já foi medida falhando. Ver
[o gate acusa AUSENTE](#o-gate-acusa-ausente-um-recurso-que-existe).

Há **três** `bash` nesta máquina, e eles não são intercambiáveis: o do Git para Windows (o que
os scripts esperam), o do WSL — que é outro sistema de arquivos e não enxerga o worktree — e o
que o PowerShell resolve por padrão, que costuma ser o do WSL. Daí o caminho explícito.

---

## As coordenadas da plataforma

Os comandos deste documento usam `<...>` para valores que a conta resolve. Descubra-os uma
vez, no começo da sessão, e mantenha-os à mão.

| Placeholder | Como descobrir |
|---|---|
| `<id-instância>` | `aws ec2 describe-instances --filters "Name=tag:Name,Values=fcg-*" --query "Reservations[].Instances[].InstanceId" --output text` |
| `<endereço-fixo>` | a mesma consulta, trocando `InstanceId` por `PublicIpAddress` |
| `<id-broker>` | sai do apply da abertura como `broker_name`; ou `aws mq list-brokers --query "BrokerSummaries[?starts_with(BrokerName,'fcg')].BrokerId" --output text` |
| `<api>` | `aws apigatewayv2 get-apis --query "Items[?starts_with(Name,'fcg')].ApiId" --output text` |
| `<região>` | `us-east-1` |
| `<repo-da-função>` | onde estiver o clone do repositório da função serverless — outro worktree, fora deste repositório |

O identificador da instância e o endereço fixo **não mudam entre sessões** — o endereço é
associado e sobrevive à parada. O do broker muda a cada sessão, porque o broker é recriado.

---

## Antes de iniciar a instância

Estes dois passos custam **zero** — a instância ainda está parada. É onde a sessão se salva.

### 1. Conferir o endereço administrativo

A regra de SSH autoriza um endereço `/32`: o da máquina de quem administra. Ele **caduca
quando o provedor troca o IP** — medido acontecendo com **um dia** de intervalo, não meses.
Descobrir isso depois custa o tempo de diagnóstico com a instância de pé e cobrando.

```bash
curl https://checkip.amazonaws.com
grep admin_cidr terraform/platform/terraform.tfvars
```

Se divergirem, atualize o `terraform.tfvars` e reaplique:

```bash
terraform -chdir=terraform/platform apply
```

O plano tem de sair **`0 to add, 1 to change, 0 to destroy`** — só o endereço da regra de
ingresso. Qualquer coisa além disso é sinal de que algo mais mudou; leia antes de confirmar.

### 2. Preparar a invocação do inventário

O `inventario-aws.sh` é o gate de abertura e de fechamento. Nesta máquina ele exige **duas
medidas juntas** — uma sozinha produz falso negativo. Ver
[o gate acusa AUSENTE](#o-gate-acusa-ausente-um-recurso-que-existe).

Do PowerShell:

```powershell
$env:MSYS2_ARG_CONV_EXCL = '*'
& "C:\Program Files\Git\bin\bash.exe" scripts/inventario-aws.sh
```

Saídas: `0` inventário correto · `1` sobrou recurso cobrado por hora · `2` falta peça do
permanente.

**A abertura só continua com `exit 0`.** Recurso cobrado sobrando de uma sessão anterior é
justamente o que este gate existe para pegar.

---

## Abertura

O broker leva ~12 minutos para nascer. Dispare-o **primeiro e sem esperar**, e use esse tempo
para o resto — é o pedágio em paralelo.

### 1. Disparar o broker (só perfil Saga)

```bash
terraform -chdir=terraform/session apply
```

Sempre com `-chdir`. Aplicar no root errado sai `exit 0` com `No changes` e broker nenhum
criado — ver [comando que passa por não ter feito nada](#comando-que-passa-por-não-ter-feito-nada).

O plano tem de sair **`13 to add, 0 to change, 0 to destroy`** — o broker, seu grupo de
segurança, as regras e os endpoints de interface. Número diferente merece leitura antes de
confirmar. Se o root nunca foi inicializado nesta máquina, rode
`terraform -chdir=terraform/session init` antes. **Nenhum `-var` é necessário:** o padrão já é
o estado correto.

O broker leva ~12 minutos para ficar disponível — medido em 12m12s.

Anote os dois outputs (`broker_name` e `broker_endpoint`) e **siga para o passo 2 sem
esperar**. A senha não sai por output nenhum: ela vive no gerenciador de segredos.

### 2. Iniciar a instância

```bash
aws ec2 start-instances --instance-ids <id-instância>
aws ec2 wait instance-running --instance-ids <id-instância>
ssh ec2-user@<endereço-fixo>
```

O endereço IP é fixo e associado — não muda entre sessões. A chave é a padrão do laptop, sem
`-i`.

O SSH pode avisar que a conexão **não usa troca de chaves pós-quântica**. É observação do
cliente novo sobre o servidor da instância, não erro nem falha de autenticação: a sessão
prossegue normalmente.

### 3. Atualizar o worktree da instância

A instância **não tem `git`**, e o clone não traria os Secrets materializados nem o arquivo
de variáveis, que são não-versionados. O caminho é transferir o worktree do laptop:

```bash
tar --exclude=.git --exclude=.venv --exclude='.env*' --exclude='*.pem' \
    --exclude=terraform -cz k8s scripts observability | \
  ssh ec2-user@<endereço-fixo> 'mkdir -p ~/fcg-ops && tar -xz -C ~/fcg-ops'
```

O `mkdir -p` cobre a instância que ainda não tem o diretório; onde ele já existe, não faz nada.

**Ordem obrigatória: worktree primeiro, arquivo de perfil depois.** O inverso produz um
script lendo `.env.ec2` enquanto o outro escreve em `.env`, sem erro nenhum — o valor
simplesmente não alcança o cluster, e o sintoma aparece longe da causa.

Na instância, o arquivo de perfil é `.env.ec2`.

### 4. Inspecionar o cluster — não reaplicar

O k3s e o etcd persistem no volume: os objetos do cluster **sobrevivem à parada**, e só os
containers reiniciam. O `apply-all.sh` **não precisa rodar** a cada sessão. Inspecione:

```bash
kubectl get pods -n fcg
kubectl get jobs -n fcg
```

As duas consultas, não só a primeira. Um Job de migration `Failed` herdado de sessão anterior
faz uma reaplicação futura esperar **dez minutos em silêncio**, dentro da janela paga, sem
que a mensagem diga que está esperando Job.

O esperado na nuvem é **doze pods** `Running` e **três Jobs** `Complete`. O `get pods` mostra
quinze linhas: as três a mais são os pods dos Jobs, que ficam `Completed` e não contam como
`Running`.

| | |
|---|---|
| Serviços | `identity-api`, `catalog-api`, `payments-api` |
| Bancos | `sqlserver-identity-0`, `postgres-catalog-0`, `postgres-payments-0`, `redis` |
| Observabilidade | `grafana`, `prometheus`, `loki`, `tempo`, `otel-collector` |
| Jobs | `identity-migrate`, `catalog-migrate`, `payments-migrate` |

**Nem `rabbitmq` nem `dynamodb-local` sobem na nuvem, e isso é correto.** Lá o broker é o
serviço gerenciado e o read model é a tabela real — os dois só existem como pod no perfil local,
onde o emulador faz o papel deles. Quem conhece o ambiente local conta os pods aqui e conclui
que faltam dois; não faltam.

**Inspecionar cedo demais engana.** Nos primeiros minutos depois do boot os três serviços
aparecem `0/1 Running` — ou mesmo `Unknown`, enquanto o nó reassume os pods —, porque as probes
ainda não fecharam. Não é defeito: é o cluster voltando. Em vez de contar na hora, espere a
convergência:

```bash
kubectl wait --for=condition=ready pod -l app=identity-api -n fcg --timeout=180s
kubectl wait --for=condition=ready pod -l app=catalog-api  -n fcg --timeout=120s
kubectl wait --for=condition=ready pod -l app=payments-api -n fcg --timeout=120s
```

Tudo `Running` e os Jobs `Complete` → siga. Cluster vazio ou serviços faltando → o
procedimento é o de [levantar-do-zero.md](levantar-do-zero.md#a-camada-de-workloads).

### 5. Confirmar o broker disponível (só perfil Saga)

```bash
aws mq describe-broker --broker-id <id-broker> --query 'BrokerState'
```

Espere `RUNNING`. A versão do motor sobe de patch na janela de manutenção — a versão menor é
que está fixada, e a exata só se sabe consultando.

### 6. Preencher o endereço do broker, criar a topologia — nesta ordem

Os três passos seguintes têm **ordem obrigatória**, e todos rodam **na instância**.

```bash
# na instância, em ~/fcg-ops
./scripts/broker-env.sh
```

Ele descobre o broker pelo nome, lê a credencial do gerenciador de segredos e escreve três
chaves no arquivo de perfil. A senha nunca é impressa. Só o endereço estava obsoleto — porta
e TLS já ficam corretos entre sessões.

```bash
ENV_FILE=.env.ec2 ./scripts/topologia.sh
```

**Passe o `ENV_FILE` explicitamente.** O script hoje escolhe o arquivo por perfil, como os
outros dois, e o próprio `broker-env.sh` termina imprimindo a forma equivalente
(`FCG_PERFIL=ec2 bash scripts/topologia.sh`) — as duas funcionam e criam a mesma topologia. O
`ENV_FILE` explícito vence qualquer recuo, e é a defesa contra um worktree defasado na
instância, que é um estado em que ela já foi encontrada.

O que **não** protege nem uma forma nem a outra: um arquivo de perfil com o endereço de uma
sessão anterior tem todas as chaves preenchidas, passa na pré-condição e cria a topologia no
broker errado. A defesa é a ordem — `broker-env.sh` **antes** de `topologia.sh`, sempre.

Depois, re-materialize a configuração, **aplique-a no cluster** e reinicie os serviços para que
leiam o endereço novo:

```bash
FCG_PERFIL=ec2 ./scripts/init-secrets.sh

kubectl apply -f k8s/03-services/identity/configmap-env.yaml \
              -f k8s/03-services/identity/secret.yaml \
              -f k8s/03-services/catalog/configmap-env.yaml \
              -f k8s/03-services/catalog/secret.yaml \
              -f k8s/03-services/payments/configmap-env.yaml \
              -f k8s/03-services/payments/secret.yaml \
              -f k8s/02-observability/grafana/secret.yaml \
              -f k8s/02-observability/grafana/deployment.yaml

kubectl rollout restart deployment -n fcg
```

**O `apply` do meio não é opcional.** O `init-secrets.sh` só **escreve arquivos** — não há
nenhuma chamada a `kubectl` dentro dele. Sem o `apply`, o `rollout restart` recria os pods
montando o ConfigMap **antigo** do cluster, com o endereço do broker da sessão passada. Não sai
erro em lugar nenhum: os serviços ficam `1/1 Running` acumulando falha de conexão em laço, e o
sintoma só aparece na quinta prova da sessão verde, longe da causa.

O endereço do broker vive no ConfigMap e a credencial no Secret. A credencial é estável entre
sessões — o segredo é permanente —, mas aplicar os dois custa o mesmo e não depende dessa
estabilidade continuar valendo.

Ao fim, confirme que o endereço chegou ao cluster:

```bash
kubectl get configmap catalog-env -n fcg -o jsonpath='{.data.RabbitMq__Host}'
```

Tem de ser o endereço do broker **desta** sessão.

### 7. Aplicar o root da função (só perfil Saga)

Este passo roda **no repositório da função** — outro worktree, com Terraform próprio:

```bash
terraform -chdir=<repo-da-função>/terraform apply
```

Nenhum `-var` é necessário: o arquivo de variáveis de lá já traz o nome do broker e o
identificador do segredo, ambos estáveis entre sessões.

O plano tem de sair **`8 to add, 0 to change, 0 to destroy`** — a função, a tabela de
idempotência, o papel e a política, o grupo de log, o empacotamento e os dois mapeamentos de
origem. Leva 4–6 minutos: os mapeamentos nascem em paralelo e dominam o tempo — medidos em
4m14s e 4m46s, num apply de 5m42s —; o resto sai em segundos.

Por último, e **depois da topologia existir**. São duas dependências, não uma:

- o broker tem de estar de pé, porque o root de lá o resolve **por nome**, e a consulta falha
  enquanto ele não existir;
- **a fila antes do mapeamento de origem** — mapeamento que aponta para fila inexistente não
  dá erro, dá silêncio, e o diagnóstico sai com o broker cobrando.

---

## Sessão verde

Cinco provas, nesta ordem. Cada uma isola uma camada.

```bash
API=https://<api>.execute-api.<região>.amazonaws.com
```

**1. Rota protegida sem token → 401 da borda.**

```bash
curl -i "$API/api/jogos"
```

A resposta vem **sem** o cabeçalho `Server` e **com** `apigw-requestid`: foi o gateway que
barrou, o backend nunca acordou.

**2. Login → 200 com token.**

```bash
curl -s -X POST "$API/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@fcg.com","senha":"<senha-do-administrador>"}'
```

O usuário administrativo é semeado na migration. A senha é a `ADMINSEED_PASSWORD` do **arquivo
de perfil da instância** — não a do laptop, que carrega placeholders. Rodar o login de dentro
da instância evita que ela apareça no histórico do terminal local:

```bash
# na instância, em ~/fcg-ops
SENHA=$(grep '^ADMINSEED_PASSWORD=' .env.ec2 | cut -d= -f2-)
```

O `iss` do token decodificado tem de ser **igual** à URL do gateway. Se der 401 na próxima
prova com este token válido, ver [401 com token válido](#401-com-token-válido-em-rota-protegida).

**3. Discovery pelo gateway → 200.**

```bash
curl -s "$API/.well-known/openid-configuration"
```

O `issuer` do documento é o mesmo do token. É o discovery circular vivo — o mesmo caminho que
o authorizer percorre em runtime.

**4. Rota protegida com token → 200.**

```bash
curl -i -H "Authorization: Bearer $TOKEN" "$API/api/jogos"
```

Agora **com** `Server: Kestrel`. É a prova de que o caminho privado funciona de ponta a
ponta: gateway → VPC Link → descoberta → porta de nó → serviço.

**5. Mensageria (só perfil Saga).** Um pedido credita a biblioteca e a função registra a
notificação:

```bash
curl -i -X POST "$API/api/pedidos" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jogoId":"..."}'
```

A prova de consumo são **três coisas juntas**: `consumers=1` na fila, `message_stats` com
`publish` e `deliver_get`, e a existência de stream de log da função. Não é o campo de
resultado do mapeamento — ver [o mapeamento não consome](#o-mapeamento-não-consome).

A saga interna se lê pelas filas, e ela é independente da função:

```bash
# na instância, em ~/fcg-ops
U=$(grep '^RABBITMQ_USER=' .env.ec2 | cut -d= -f2-)
P=$(grep '^RABBITMQ_PASSWORD=' .env.ec2 | cut -d= -f2-)
H=$(grep '^RABBITMQ_HOST=' .env.ec2 | cut -d= -f2-)
curl -sS -u "$U:$P" "https://$H/api/queues"
```

As filas de serviço (`order-placed.fcg-payments`, `payment-processed.fcg-catalog` e
`payment-processed.fcg-catalog-projections`) saem com `consumers=1` e `messages=0` — publicado e
consumido. As duas da função ficam com `consumers=0` enquanto o passo 7 não tiver rodado, e a
mensagem **acumula** ali: é o retrato de topologia correta sem consumidor, não de falha.

> **Read model e cache não têm prova própria nesta lista.** As rotas do catálogo os exercitam
> por baixo, mas nenhuma das cinco os isola. Ao procurar um caminho, note que `/api/biblioteca`
> só existe como `/api/biblioteca/{proxy+}` — o caminho sem sufixo devolve 404 **do gateway**
> (sem `Server`), e um sufixo inexistente devolve 404 **do backend** (com `Server: Kestrel`).
> Os dois códigos são iguais e as causas são opostas.

---

## Acesso ao Grafana

Túnel SSH em duas etapas. Nada é exposto: o Service continua interno, não há rota no gateway
para ele, e o grupo de segurança não ganha abertura nenhuma além do SSH que já existia.

```bash
ssh -f -L 3000:localhost:3000 ec2-user@<endereço-fixo> \
  'kubectl port-forward -n fcg svc/grafana 3000:3000'
```

O `localhost:3000` do `-L` resolve **na instância**, não no laptop — quem escuta lá é o
encaminhamento. São três portas 3000 em três máquinas.

**O `-f` não devolve o terminal aqui.** Ele manda o SSH para segundo plano antes de executar o
comando remoto, mas o `kubectl port-forward` não termina — a sessão fica presa até ser
interrompida. A forma que devolve o prompt é separar as duas etapas:

```bash
# na instância, em segundo plano
ssh ec2-user@<endereço-fixo> 'nohup kubectl port-forward -n fcg svc/grafana 3000:3000 >/dev/null 2>&1 &'

# no laptop, só o encaminhamento
ssh -f -N -L 3000:localhost:3000 ec2-user@<endereço-fixo>
```

Abra `http://localhost:3000`.

O túnel morre com a parada da instância. **Mas a porta local pode ficar presa** se o processo
do laptop for morto sem fechar o socket — o encaminhamento seguinte falha em `connect` com a
3000 aparentemente livre. `Get-NetTCPConnection -LocalPort 3000 -State Listen` mostra o socket
órfão; usar outra porta local (`-L 3001:localhost:3000`) contorna sem esperar.

A credencial administrativa vem do Secret gerado pelo `init-secrets.sh` a partir do arquivo de
perfil — **desde que o Secret e o Deployment tenham sido aplicados**, o que o passo 6 da
abertura faz. Sem isso o cluster continua rodando a versão anterior do Deployment, com a
credencial embutida no manifesto, e nenhum sintoma denuncia a diferença: o dashboard abre
normalmente com o valor antigo.

Para conferir de que origem vem, olhe a estrutura e não a senha:

```bash
kubectl get deployment grafana -n fcg -o jsonpath='{.spec.template.spec.containers[0].envFrom}'
```

Tem de sair `[{"secretRef":{"name":"grafana-secret"}}]`, e a lista `env` do mesmo container tem
de estar vazia. Comparar senhas não discrimina: se o arquivo de perfil trouxer `admin`, os dois
caminhos aceitam a mesma coisa.

> **Postura:** o Service é interno e o acesso depende de já se ter SSH na instância. Se ele um
> dia ganhar exposição, a credencial passa a valer sozinha como defesa, e a força dela no
> arquivo de perfil vira o que separa o dashboard da internet.

---

## Fechamento

**Nesta ordem, e a ordem importa.**

**1. Root da função** (só perfil Saga), no repositório da função:

```bash
terraform -chdir=<repo-da-função>/terraform destroy
```

Primeiro, sempre: o mapeamento de origem aponta para o broker, e destruir o broker antes deixa
mapeamento órfão. A função e o mapeamento estão entre os **proibidos entre sessões** — se
sobrarem, o inventário do passo 4 sai `exit 1`.

Sai `7 destroyed` em menos de meio minuto — a destruição é muito mais rápida que a criação, e os
mapeamentos que levaram minutos para nascer somem em segundos.

**2. Root de sessão** (só perfil Saga):

```bash
terraform -chdir=terraform/session destroy
```

Leva ~13 minutos e sai `13 destroyed`, casando com o `13 to add` da abertura. O tempo é
dominado pelos endpoints de interface, não pelo broker.

**3. Parar a instância — nunca terminar:**

```bash
aws ec2 stop-instances --instance-ids <id-instância>
aws ec2 wait instance-stopped --instance-ids <id-instância>
```

O volume guarda o cluster, as imagens e as variáveis. Terminar joga tudo isso fora e a
próxima sessão vira um levantamento do zero.

**Espere o `stopped`.** Instância em `stopping` faz a consulta do gate retornar vazio, e um
fechamento apressado colhe um falso `exit 2` — a instância aparece como ausente do
inventário quando só está a caminho.

**4. Inventário, que sai zero:**

```powershell
$env:MSYS2_ARG_CONV_EXCL = '*'
& "C:\Program Files\Git\bin\bash.exe" scripts/inventario-aws.sh
```

`exit 0` fecha a sessão. `exit 1` significa que sobrou recurso cobrado por hora — leia as
linhas marcadas e destrua antes de sair.

> O gate **não conta grupos de segurança**. Eles são destruídos junto com o broker; se um dia
> um destroy parcial deixar um para trás, o inventário sai zero com recurso sobrando.

---

## Inventário permanente

O que fica de pé entre sessões, e o que cada peça custa parada:

| Peça | Quantidade | Custo/mês |
|---|---|---|
| Instância do cluster, parada, com volume | 1 | ~US$1,30 |
| Endereço IP fixo, associado | 1 | ~US$3,60 |
| API HTTP, authorizer JWT, VPC Link | 1 cada | — |
| Namespace, serviços e registros de descoberta | 1 / 2 / 2 | ~US$0,30 |
| Tabela do read model | 1 | ~US$0 |
| Segredo da credencial do broker | 1 | ~US$0,40 |
| Grupo de log de acesso do gateway | 1 | — |
| **Total parado** | | **~US$5,60** |

O segredo é **permanente**: é ele que mantém a credencial estável entre sessões. Seu
identificador só muda se o próprio segredo for recriado.

Proibidos entre sessões — achar qualquer um destes é `exit 1`: broker gerenciado, mapeamento
de origem de eventos, função serverless e tabela de idempotência da função.

---

## Diagnóstico

Sintoma → causa → conserto. Cada item aqui custou pelo menos uma sessão para ser medido.

### SSH parou do nada, com a instância de pé

`ssh: connect to host ... port 22: Connection timed out`, sem que nada tenha mudado no
repositório.

O endereço administrativo autorizado caducou: o provedor trocou o IP de saída. Medido
acontecendo com um dia de intervalo, mesmo bloco do provedor e último octeto diferente.

Conserto: atualizar o `admin_cidr` e reaplicar o root permanente. O plano sai
`0 to add, 1 to change, 0 to destroy`. É o passo 1 da abertura justamente para que o
diagnóstico não aconteça com a instância cobrando.

### O gate acusa `AUSENTE` um recurso que existe

O inventário reporta, por exemplo, `AUSENTE grupo de log de acesso do gateway (0 de 1)`,
enquanto a consulta direta mostra o recurso presente e íntegro.

O único argumento do script que começa com `/` é reescrito pela conversão de caminho
POSIX→Windows antes de chegar ao executável, e a chamada morre. Sob o tratamento de erro da
consulta, isso vira "ausente" silencioso.

Conserto: as **duas** medidas juntas, sempre.

```powershell
$env:MSYS2_ARG_CONV_EXCL = '*'
& "C:\Program Files\Git\bin\bash.exe" scripts/inventario-aws.sh
```

Elas resolvem problemas **diferentes** — o caminho explícito escolhe o interpretador, a
variável conserta a conversão — e cada uma sozinha já foi medida falhando. Invocar pelo
caminho explícito sem a variável mantém o processo filho fazendo a conversão; usar a variável
sem o caminho explícito cai no interpretador errado, que não enxerga o worktree.

### 401 com token válido em rota protegida

O login devolve 200, o token parece bom, e toda rota protegida devolve 401. Parece erro de
assinatura; é erro de string.

Os dois endereços do gateway diferem por uma **barra final**. O emissor configurado tem de
receber o valor **sem** barra; colar o valor de invocação produz um emissor com barra,
divergente do que o authorizer espera.

Conserto: corrigir a variável de emissor no arquivo de perfil, re-materializar a configuração
e reiniciar os serviços. O endereço público tolera as duas formas, porque o serviço apara a
barra — só o emissor é estrito.

### Em que camada a resposta morreu

Um 401 do gateway e um 401 do serviço têm o mesmo código. O discriminador é o cabeçalho
`Server`:

| Cabeçalho | Quem respondeu |
|---|---|
| `Server` presente | o backend — a requisição atravessou a borda |
| `Server` ausente, com `apigw-requestid` | a borda barrou — o backend nunca acordou |

É o teste mais barato disponível. A alternativa é procurar ausência de linha no log do
backend, que custa uma consulta e uma âncora.

### `broker-env.sh` com `Connect timeout`, e o resto da instância saudável

A instância alcança a internet normalmente, mas a leitura do segredo pendura.

O nome privado do endpoint de interface faz **toda** a VPC resolver aquele serviço para o
endereço privado do endpoint — inclusive quem lia pela internet e não tinha problema nenhum.
Se o grupo do endpoint não autorizar a origem, ela passa a ser barrada.

Diagnóstico: consulte pelo resolvedor da VPC, **nunca** por `getent` ou `ping`.

```bash
dig +short A <serviço>.<região>.amazonaws.com @10.0.0.2
```

`getent` responde do cache local e pode devolver endereço IPv6 público, enquanto o caminho
real é IPv4 — foi isso que fez o sintoma parecer intermitente. A chave de comparação é sempre
**o nome**: o endereço privado do endpoint muda a cada sessão.

### O mapeamento não consome

O campo de último resultado de processamento é **retrato da última tentativa falha**, não
estado corrente: ele continua acusando erro depois de a função já ter sido invocada com
sucesso. Ler só esse campo dá "ainda quebrado" com o caminho funcionando.

A prova de consumo são três coisas juntas: `consumers=1` na fila, `message_stats` com
`publish` e `deliver_get`, e a existência de stream de log.

Ao procurar a invocação no log, **enumere as streams sem limite**. Limitar a consulta a um item
devolve a stream errada por causa da paginação. A stream é por **ambiente de execução**, não por
invocação: invocações próximas reaproveitam a mesma (o campo `cold_start` distingue a primeira
das seguintes), e uma pausa longa o bastante para reciclar o ambiente abre outra.

Se o mapeamento realmente não alcançar o broker, a mensagem de erro avança a cada conserto —
é a única forma de saber que o anterior pegou. Dois fatos que se generalizam: grupo declarado
como recurso nasce **sem** a saída irrestrita que o console adiciona por padrão, e **tráfego
entre membros do mesmo grupo não é liberado implicitamente**.

### O painel de 4xx não desenha

O painel devolve vetor vazio na maior parte do tempo, e os 401 e 404 da borda não aparecem em
painel nenhum. **Isso é por construção, não defeito.**

O gateway redige o 401 do authorizer e o 404 de rota não declarada **antes** do VPC Link: o
backend nunca é acordado, então não incrementa métrica de servidor. Numa medição de 60
requisições, 36 (60%) não apareceram em painel nenhum.

O painel responde *"meus serviços estão saudáveis?"*, **não** *"o que meus usuários
receberam?"*. Para a segunda pergunta, a fonte é o grupo de log de acesso do gateway.

A exceção que confirma a regra: um 429 de throttle **aparece**, porque o throttle é aplicado
depois do roteamento e o serviço o contabilizou. O discriminador não é "erro de infra vs. de
aplicação" — é **quem redigiu a resposta**.

### `kubectl apply -R` aplica também os templates

Os diretórios de manifesto guardam, lado a lado, o arquivo real (`secret.yaml`) e o template
versionado com placeholder (`secret.example.yaml`). Um `kubectl apply -R -f k8s/` aplica os
**dois**, e o que vale é o último a ser aplicado.

Hoje o acaso protege: `secret.example.yaml` ordena antes de `secret.yaml`, então o real vence e
nada quebra. É proteção frágil — depende de nome de arquivo, não de intenção. Renomear um
template ou acrescentar um sufixo pode inverter a ordem, e o sintoma seria um Secret com
placeholder no cluster, sem erro em lugar nenhum.

O `apply-all.sh` **não** tem esse risco: ele filtra explicitamente (`! -name '*.example.yaml'`).
O risco é do `apply -R` digitado à mão. Aplique pelo script, ou nomeie os arquivos um a um.

### O Job de migration exige a chave RSA, não só o banco

O `identity-migrate` não sobe só com a connection string: ele cobra também
`Jwt__RsaPrivateKeyPem`. Faltando a chave, o Job falha por motivo que não menciona chave
nenhuma, e a leitura natural é procurar defeito no banco.

A chave sai do `init-secrets.sh`, que a gera se não encontrar nenhuma — então o caminho normal
já cobre. O caso que morde é materializar Secret à mão, pulando o script.

### Senha nova de Postgres não vale em volume que já existe

A senha do Postgres é gravada **na inicialização do volume**, e só nela. Trocar
`POSTGRES_CATALOG_PASSWORD` no arquivo de perfil e reaplicar não muda a senha de um banco que
já nasceu: o volume persiste, a variável nova é ignorada, e o serviço passa a falhar
autenticação com `28P01`.

Num levantamento do zero isso não aparece — o volume é novo. Aparece ao reaplicar sobre um
cluster que já rodou. Conserto: `ALTER USER` no banco de pé, ou destruir o volume e deixá-lo
renascer.

### Comando que passa por não ter feito nada

`terraform apply` no root errado sai `exit 0` com `No changes` e **nada criado**. Já
aconteceu, e só foi pego por consulta direta ao serviço depois.

Conserto: use `-chdir=<caminho>` sempre. Ele não depende do diretório corrente.

```bash
terraform -chdir=terraform/session apply
```

A regra que generaliza: **confira o efeito, nunca o código de saída.** A mesma classe de
falha já apareceu em busca textual que sai vazia por ausência do arquivo e em contagem sobre
recurso inexistente.

### Comando na instância se comporta de forma estranha

Nenhum `$` sobrevive à travessia de camadas de citação até o interpretador da instância —
variável de laço chega vazia, documento JSON chega malformado. O sintoma é um erro que
aponta para caminho ou requisição inválida, e não para citação.

Conserto: escreva o script num arquivo e mande-o por redireção, **a partir do Git Bash**:

```bash
ssh ec2-user@<endereço-fixo> 'bash -s' < <arquivo-local>
```

Não use o encaminhamento do PowerShell por leitura de arquivo: ele acrescenta marca de ordem
de byte, e o interpretador da instância lê essa marca como parte do primeiro comando — a
primeira linha do script se perde em silêncio enquanto o resto roda.

### Conferir qual imagem um pod está rodando

A consulta por índice `{.items[0]}` **mente durante um rollout**: o primeiro item pode ser o
pod em terminação, com a imagem velha. Enumere todos, incluindo a fase:

```bash
kubectl get pods -n fcg -o custom-columns=NOME:.metadata.name,FASE:.status.phase,IMAGEM:.spec.containers[0].image
```

### Verificar alguma coisa de dentro de um pod de serviço

As imagens dos serviços **não trazem `curl`**, e o cliente HTTP embutido não faz requisição
com método arbitrário — ele imprime o texto de uso, que se confunde com erro de plataforma.
O que funciona é falar HTTP cru:

```bash
printf 'GET /caminho HTTP/1.1\r\nHost: destino\r\nConnection: close\r\n\r\n' | nc -w 5 destino 80
```

As probes do Deployment não são afetadas: quem as executa é o kubelet, não o container.
