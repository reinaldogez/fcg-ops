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

O endereço IP é fixo e associado — não muda entre sessões.

### 3. Atualizar o worktree da instância

A instância **não tem `git`**, e o clone não traria os Secrets materializados nem o arquivo
de variáveis, que são não-versionados. O caminho é transferir o worktree do laptop:

```bash
tar --exclude=.git --exclude=.venv --exclude='.env*' --exclude='*.pem' \
    --exclude=terraform -cz k8s scripts observability | \
  ssh ec2-user@<endereço-fixo> 'tar -xz -C ~/fcg-ops'
```

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

**Passe o `ENV_FILE` explicitamente.** Ao contrário dos outros dois scripts, este não escolhe
o arquivo por perfil: sem a variável ele lê `.env`, que na instância não é o arquivo que o
`broker-env.sh` acabou de escrever.

Depois, re-materialize a configuração e reinicie os serviços para que leiam o endereço novo:

```bash
FCG_PERFIL=ec2 ./scripts/init-secrets.sh
kubectl rollout restart deployment -n fcg
```

### 7. Aplicar o root da função (só perfil Saga)

No repositório da função, por último. **A fila antes do mapeamento de origem**: mapeamento
que aponta para fila inexistente não dá erro — dá silêncio, e o diagnóstico sai com o broker
cobrando.

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
  -d '{"email":"...","senha":"..."}'
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

---

## Acesso ao Grafana

Túnel SSH em duas etapas. Nada é exposto: o Service continua interno, não há rota no gateway
para ele, e o grupo de segurança não ganha abertura nenhuma além do SSH que já existia.

```bash
ssh -f -L 3000:localhost:3000 ec2-user@<endereço-fixo> \
  'kubectl port-forward -n fcg svc/grafana 3000:3000'
```

O `localhost:3000` do `-L` resolve **na instância**, não no laptop — quem escuta lá é o
encaminhamento. São três portas 3000 em três máquinas. O túnel morre com a parada da
instância e não deixa resíduo: é processo, não recurso.

Abra `http://localhost:3000`.

A credencial administrativa vem do Secret gerado pelo `init-secrets.sh` a partir do arquivo
de perfil — não é a embutida na imagem.

> **Postura:** o Service é interno e o acesso depende de já se ter SSH na instância. Se ele um
> dia ganhar exposição, a credencial passa a valer sozinha como defesa, e a força dela no
> arquivo de perfil vira o que separa o dashboard da internet.

---

## Fechamento

**Nesta ordem, e a ordem importa.**

**1. Root da função** (só perfil Saga). Primeiro, sempre: o mapeamento de origem aponta para
o broker, e destruir o broker antes deixa mapeamento órfão.

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

Ao procurar a invocação no log, **enumere as streams sem limite**. A função cria uma stream
por invocação, e limitar a consulta a um item devolve a stream errada por causa da paginação.

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
