# Levantar a plataforma do zero

> **Uso único por plataforma.** Este documento levanta a plataforma numa conta virgem — ou a
> relevanta depois de um `destroy` completo. **Sessão de rotina não repete isto** — para abrir
> e fechar uma sessão com a plataforma já de pé, use o
> [runbook-sessao.md](runbook-sessao.md).

A distinção não é de conveniência. O passo 1 daqui aplica a borda **com a autenticação
desligada**, e repeti-lo numa sessão comum derrubaria a autenticação da plataforma. Depois
que a plataforma existe, o padrão já é o estado estável correto e o interruptor não se usa
mais.

## Sumário

- [A ordem entre camadas](#a-ordem-entre-camadas)
- [Por que duas fases](#por-que-duas-fases)
- [Passo 1 — plataforma sem autenticação de borda](#passo-1--plataforma-sem-autenticação-de-borda)
- [Passo 2 — a camada de workloads](#passo-2--a-camada-de-workloads)
- [Passo 3 — plataforma no padrão](#passo-3--plataforma-no-padrão)
- [Passo 4 — sessão e função](#passo-4--sessão-e-função)
- [A barra do endereço de teste](#a-barra-do-endereço-de-teste)
- [Expectativa de tempo](#expectativa-de-tempo)

---

## A ordem entre camadas

É aqui que o erro mora. A ordem não é preferência — cada passo depende de um efeito
observável do anterior:

```
1. plataforma, interruptor desligado   → API, rede, instância, tabela, segredo
2. cluster de pé                       → identity servindo o documento de discovery
3. plataforma, padrão                  → authorizer e rotas protegidas
4. sessão + função                     → broker, topologia, mapeamento
```

Aplicar o passo 3 antes do 2 falha com erro de requisição inválida na criação do authorizer, e
o erro da nuvem não diz que falta o discovery. Hoje há uma rede de proteção antes dele: uma
verificação no próprio root lê o documento de descoberta e, se ele não responder 200, emite
aviso nomeando a causa. É **aviso**, não erro — o apply segue e ainda quebra —, mas o
diagnóstico vem de graça em vez de custar a sessão.

## Por que duas fases

A criação do authorizer **valida o endpoint de discovery**, não apenas o formato do emissor.
E o discovery é servido pelo identity, que está atrás de uma rota do próprio gateway.

O resultado é circular: as rotas só nascem depois do authorizer, no mesmo apply — então numa
aplicação única o authorizer é criado quando ainda não existe rota que sirva o documento que
ele precisa validar. **Não fecha em uma aplicação**, e nenhuma correção no serviço destrava,
porque o problema é de ordem de criação.

A saída é o interruptor `authorizer_ligado`. Com ele em falso, o authorizer não é criado e as
rotas protegidas ficam de fora; com o cluster de pé e o discovery respondendo, o apply no
padrão cria os dois.

O caminho está provado nas duas direções, sem migração de estado nem substituição de recurso:
desligar produziu `3 to add, 0 to change, 0 to destroy`; religar produziu
`9 added, 0 changed, 0 destroyed`, e o `plan` seguinte saiu `No changes`.

---

## Passo 1 — plataforma sem autenticação de borda

Antes do primeiro comando, confira
[a máquina de quem administra](runbook-sessao.md#a-máquina-de-quem-administra) — ferramentas
necessárias e as idiossincrasias do terminal. Uma delas produz **falso negativo no inventário
deste passo**, e some com a saída que o documento diz para esperar.

Preencha o `terraform.tfvars` a partir do `terraform.tfvars.example`, com atenção ao
`admin_cidr` — é o endereço `/32` da máquina que vai administrar, e ele caduca quando o
provedor troca o IP.

```bash
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform apply -var authorizer_ligado=false
```

Sempre com `-chdir`: apply no root errado sai `exit 0` com `No changes` e nada criado.
Revise o plano contra dimensão, exposição e ciclo de vida antes de confirmar.

**Verificação:** as três rotas abertas existem e a lista de authorizers está **vazia**.

```bash
aws apigatewayv2 get-authorizers --api-id <id> --query 'Items'
```

Guarde os outputs. Dois deles diferem por uma barra final, e a distinção custa uma sessão:
o valor de **emissor** (sem barra) é o que a configuração do cluster consome; o valor de
**invocação** (com barra) é o endereço para chamar a API. Trocá-los produz 401 com token
válido em toda rota protegida — e usar o de invocação para montar URL de teste produz um 404
que parece defeito de integração e não é. Ver [a barra do endereço de
teste](#a-barra-do-endereço-de-teste).

O emissor não é valor de leitura: **ele entra no arquivo de perfil do cluster**, em duas
chaves, antes do passo 2 começar.

```bash
grep -E 'JWT_ISSUER|JWT_PUBLIC_BASE_URL' .env.ec2
```

As duas têm de terminar no identificador da API que este passo acabou de criar. Numa conta
virgem elas nascem do `.env.example` e se preenchem à mão. Num **relevantamento** o arquivo já
existe, carregando o identificador da API anterior — e aí ele passa em toda pré-condição, o
cluster sobe inteiro e serve o emissor de uma API que não existe mais. O passo 2 tem
verificação para isso, mas o ciclo já foi gasto.

Num relevantamento três coordenadas mudam, e cada uma tem um consumidor diferente:

| Muda | Quem consome |
|---|---|
| identificador da API | `JWT_ISSUER` e `JWT_PUBLIC_BASE_URL` do `.env.ec2` |
| endereço fixo | o `known_hosts` da máquina que administra |
| sufixo do segredo | `broker_secret_arn` no root da função (passo 4) |

Rode o inventário já aqui, sabendo que ele sai **`exit 2`** com **duas** peças ausentes: o
authorizer, que só nasce no passo 3, e a instância — o gate conta instância **parada**, e ela
está de pé. O objetivo não é o gate: é exercitar as consultas enquanto a sessão está barata.

O `plan` deste passo emite um `Warning: Check block assertion known after apply`. É esperado e
não indica nada: a verificação do discovery depende do identificador da API, que ainda não
existe no momento do plano. Ele some no passo 3.

---

## Passo 2 — a camada de workloads

A instância nasce com o k3s do provisionamento inicial, e nada mais: **não tem `git`, não tem
`docker`**.

### Transferir o worktree

Clonar não serve, mesmo que `git` fosse instalado: o clone não traria os Secrets
materializados nem o arquivo de variáveis, que são não-versionados por construção.

O endereço fixo é novo, então a máquina ainda não está no `known_hosts` e o SSH pede
confirmação da impressão digital. Dentro do `tar | ssh` essa pergunta aparece no meio do
fluxo — resolva antes, com uma conexão de teste, que de quebra confirma o cluster:

```bash
ssh ec2-user@<endereço-fixo> 'kubectl get nodes'
```

O nó tem de sair `Ready`. Não é preciso `KUBECONFIG` nem `sudo`: o provisionamento deixa o
arquivo de acesso ao cluster legível de propósito.

```bash
tar --exclude=.git --exclude=.venv --exclude='.env*' --exclude='*.pem' \
    --exclude=terraform -cz k8s scripts observability | \
  ssh ec2-user@<endereço-fixo> 'mkdir -p ~/fcg-ops && tar -xz -C ~/fcg-ops'
```

Depois — e só depois — o arquivo de variáveis do perfil. **Worktree primeiro, arquivo de
perfil depois** — o inverso faz um script escrever num arquivo enquanto outro lê de outro, sem
erro nenhum.

```bash
scp .env.ec2 ec2-user@<endereço-fixo>:~/fcg-ops/
```

A chave RSA de assinatura é **opcional**: o `init-secrets.sh` gera uma se não encontrar
nenhuma, e numa plataforma recém-nascida não há token emitido que dependa da anterior.
Transfira-a apenas se quiser manter válidos tokens emitidos antes.

### Materializar e aplicar

```bash
# na instância, em ~/fcg-ops
FCG_PERFIL=ec2 ./scripts/init-secrets.sh
FCG_PERFIL=ec2 ./scripts/apply-all.sh
```

### Esperar os serviços — o script não espera

O `apply-all.sh` espera bancos e Jobs de migration, **nunca os Deployments dos serviços**.
Ele reporta `ok: manifestos aplicados` e sai `0` com serviço ainda em `0/1`. Medido nos dois
ambientes, não só na nuvem.

Acrescente a espera explícita:

```bash
kubectl wait --for=condition=ready pod -l app=identity-api -n fcg --timeout=600s
kubectl wait --for=condition=ready pod -l app=catalog-api  -n fcg --timeout=600s
kubectl wait --for=condition=ready pod -l app=payments-api -n fcg --timeout=600s
```

**Verificação do passo:** o documento de discovery responde 200 **pela URL do gateway**, com
o emissor igual à URL do gateway.

`API` recebe o valor de **emissor** — o sem barra final. É a única leitura que funciona aqui;
com o de invocação estes dois comandos saem 404. Ver [a barra do endereço de
teste](#a-barra-do-endereço-de-teste).

```bash
API=<valor-de-emissor>
curl -s "$API/.well-known/openid-configuration"
curl -s -o /dev/null -w '%{http_code}\n' "$API/.well-known/jwks.json"
```

São **duas** conferências, e a segunda é a que escapa: o status tem de ser 200 **e** o campo
`issuer` do corpo tem de ser idêntico ao `$API`. Um cluster configurado com o emissor de uma
API anterior responde 200 alegremente — o 200 sozinho não prova nada —, e quem morre disso é
o passo 3, longe daqui.

Emissor divergente se conserta na instância, sem refazer o passo 2. Corrija as duas chaves no
`.env.ec2` da máquina que administra, reenvie o arquivo, e lá dentro:

```bash
FCG_PERFIL=ec2 ./scripts/init-secrets.sh
kubectl apply -f k8s/03-services/identity/configmap-env.yaml \
              -f k8s/03-services/catalog/configmap-env.yaml \
              -f k8s/03-services/payments/configmap-env.yaml
kubectl rollout restart deployment -n fcg
kubectl rollout status deployment/identity-api -n fcg
```

O `apply` do meio não é opcional: o `init-secrets.sh` só escreve arquivos, e sem ele o
`rollout restart` recria os pods montando o ConfigMap antigo do cluster.

Este é o teste antecipado do caminho privado: gateway → VPC Link → descoberta → porta de nó →
identity é exatamente o percurso que a criação do authorizer vai fazer. Um **502** aqui se
conserta **antes** de gastar um apply — e o conserto é mapeamento de parâmetro na integração,
se o encaminhamento não preservar o caminho. Um **404**, porém, quase sempre é a barra, e não
a integração.

---

## Passo 3 — plataforma no padrão

Com o discovery respondendo, aplique sem o `-var`:

```bash
terraform -chdir=terraform/platform apply
```

**Verificação:**

1. O apply conclui e o authorizer existe.
2. `terraform -chdir=terraform/platform plan` logo depois **não acusa mudança** — é a prova
   de que o padrão deixa o estado estável correto, e de que o interruptor não é mais
   necessário em apply nenhum.
3. `scripts/inventario-aws.sh` lista todo o permanente com `ok` **menos a instância**, e sai
   `exit 2`. Isso é o certo aqui, e não falha: o gate conta instância **parada**, e neste ponto
   ela está obrigatoriamente de pé — é ela que serve o discovery que o passo 3 acabou de
   consumir. O inventário só é exigível em zero depois que o fechamento da sessão para a
   máquina.

A partir daqui a plataforma existe, e toda sessão seguinte usa o
[runbook-sessao.md](runbook-sessao.md).

---

## Passo 4 — sessão e função

Só se a primeira sessão for do perfil Saga. O procedimento é o mesmo da abertura de rotina —
ver [Abertura](runbook-sessao.md#abertura), passos 1, 5, 6 e 7 — e a ordem obrigatória vale
igual: **a fila antes do mapeamento de origem**.

O root da função consome dois valores: o nome do broker (output do root de sessão) e o
identificador do segredo da credencial. O segredo é **permanente** — ele nasce no root da
plataforma e é o que mantém a credencial estável entre sessões. Seu identificador só muda se
o próprio segredo for recriado — que é exatamente o caso aqui, porque o passo 1 acabou de
criá-lo do zero.

Atualize `broker_secret_arn` no `terraform.tfvars` do repositório da função com o ARN que o
passo 1 devolveu. O sufixo aleatório muda a cada recriação do segredo, e o plano de lá não
fecha com o antigo.

---

## A barra do endereço de teste

Custa uma sessão e não parece o que é. O passo 1 devolve dois endereços que diferem por uma
barra final, e o de **invocação** — o com barra — é o que se copia por instinto para montar
URL de teste. Montada assim, a URL fica com barra dupla:

```
https://<id>.execute-api.<região>.amazonaws.com//.well-known/openid-configuration
                                               ↑↑
```

**Medido: 404.** O mesmo caminho com uma barra só: **200**. O gateway casa rota por caminho
literal, e `//.well-known/{proxy+}` não é `/.well-known/{proxy+}`.

O que torna isso caro é o diagnóstico natural: 404 numa rota que existe parece defeito de
encaminhamento, e manda investigar o mapeamento de parâmetro da integração — que está certo.
Antes de suspeitar da integração, **conte as barras**.

Regra prática: o valor de **emissor** (sem barra) serve para montar URL e para configurar o
cluster; o de **invocação** (com barra) serve para colar no navegador, e nada mais.

---

## Expectativa de tempo

| Etapa | Medido |
|---|---|
| Passo 1 — plataforma sem borda | 3–5 min (uma medição: apply em 2m42s) |
| Passo 2 — workloads num cluster recriado | **2–20 min**, ver abaixo |
| Passo 3 — plataforma no padrão | 1–2 min (uma medição: apply em 40s) |
| Passo 4 — broker nascendo | ~12 min |

O passo 2 é o que varia, e **os pulls de imagem são a variação** — não o banco. Duas medições
do mesmo passo, ambas em cluster recriado e cache de nó frio, saíram muito distantes: uma
gastou 20+ minutos, com a infraestrutura levando ~9 só para ficar pronta e uma única imagem
consumindo quase 3 de download; outra fechou o `apply-all.sh` inteiro em **1m30s**, com os
três serviços já `ready` quando as esperas explícitas rodaram. Planeje pelo pior caso, e não
conclua que algo está errado quando vier o melhor.

A diferença entre *recriar o cluster* e *reaplicar num cluster existente* é o cache de
imagens do nó, e ela é grande. É por isso que o fechamento **para** a instância em vez de
terminá-la: o volume guarda o cluster e as imagens.

---

## Se algo não fechar

A seção de [Diagnóstico](runbook-sessao.md#diagnóstico) do runbook de sessão cobre os
sintomas medidos — emissor com barra, falso negativo do inventário, resolução de nome dentro
da VPC, camada em que a resposta morreu, e as armadilhas de executar comando na instância.
Ela vale igual aqui.
