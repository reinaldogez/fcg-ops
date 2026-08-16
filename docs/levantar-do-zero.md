# Levantar a plataforma do zero

> **Uso único.** Este documento levanta a plataforma numa conta virgem. **Sessão de rotina
> não repete isto** — para abrir e fechar uma sessão com a plataforma já de pé, use o
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

Aplicar o passo 3 antes do 2 falha com erro de requisição inválida na criação do authorizer,
e o diagnóstico consome a sessão inteira — o erro não diz que falta o discovery.

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
válido em toda rota protegida.

Rode o inventário já aqui, mesmo sabendo que ele vai sair diferente de zero — falta o
authorizer. O objetivo não é o gate: é exercitar as consultas enquanto a sessão está barata.

---

## Passo 2 — a camada de workloads

A instância nasce com o k3s do provisionamento inicial, e nada mais: **não tem `git`, não tem
`docker`**.

### Transferir o worktree

Clonar não serve, mesmo que `git` fosse instalado: o clone não traria os Secrets
materializados nem o arquivo de variáveis, que são não-versionados por construção.

```bash
tar --exclude=.git --exclude=.venv --exclude='.env*' --exclude='*.pem' \
    --exclude=terraform -cz k8s scripts observability | \
  ssh ec2-user@<endereço-fixo> 'mkdir -p ~/fcg-ops && tar -xz -C ~/fcg-ops'
```

Transfira à parte o arquivo de variáveis do perfil (`.env.ec2`) e a chave RSA de assinatura.
**Worktree primeiro, arquivo de perfil depois** — o inverso faz um script escrever num
arquivo enquanto outro lê de outro, sem erro nenhum.

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

```bash
curl -s "$API/.well-known/openid-configuration"
curl -s -o /dev/null -w '%{http_code}\n' "$API/.well-known/jwks.json"
```

Este é o teste antecipado do caminho privado: gateway → VPC Link → descoberta → porta de nó →
identity é exatamente o percurso que a criação do authorizer vai fazer. Um 404 ou 502 aqui se
conserta **antes** de gastar um apply — e o conserto é mapeamento de parâmetro na integração,
se o encaminhamento não preservar o caminho.

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
3. `scripts/inventario-aws.sh` sai **zero**, listando exatamente as peças do permanente.

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
o próprio segredo for recriado.

---

## Expectativa de tempo

| Etapa | Tempo |
|---|---|
| Passo 1 — plataforma sem borda | ~5 min |
| Passo 2 — workloads num cluster recriado | **20+ min** |
| Passo 3 — plataforma no padrão | ~2 min |
| Passo 4 — broker nascendo | ~12 min |

O passo 2 domina, e **os pulls de imagem dominam o passo 2** — não o banco. Num cluster
recriado, a infraestrutura leva ~9 minutos só para ficar pronta, com uma única imagem
gastando quase 3 minutos de download.

A diferença entre *recriar o cluster* e *reaplicar num cluster existente* é o cache de
imagens do nó, e ela é grande. É por isso que o fechamento **para** a instância em vez de
terminá-la: o volume guarda o cluster e as imagens.

---

## Se algo não fechar

A seção de [Diagnóstico](runbook-sessao.md#diagnóstico) do runbook de sessão cobre os
sintomas medidos — emissor com barra, falso negativo do inventário, resolução de nome dentro
da VPC, camada em que a resposta morreu, e as armadilhas de executar comando na instância.
Ela vale igual aqui.
