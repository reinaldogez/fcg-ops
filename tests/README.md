# Testes ponta a ponta da plataforma

Verificação automatizada do que antes era conduzido à mão: o repertório roda por um comando,
imprime passa/falha por cenário e só sai zero se todos passarem.

Os testes exercitam a plataforma **pela borda pública**, como um cliente externo — com token
real, pelos mesmos endereços que qualquer consumidor usaria. Nada aqui altera infraestrutura:
a suite consome um ambiente que já esteja de pé.

## Preparo

```bash
cd tests
python -m venv .venv
.venv/Scripts/pip install -e ".[dev]"      # Linux/macOS: .venv/bin/pip
```

## Como rodar

A suite não tem endereço nem senha embutidos: os dois vêm do ambiente, e é isso que permite
apontá-la para alvos diferentes sem alterar uma linha de código.

```bash
FCG_API_BASE_URL=https://<endereco-publico-da-plataforma> \
FCG_ADMIN_PASSWORD=<senha do administrador do ambiente alvo> \
  pytest borda -v
```

No Windows, com PowerShell:

```powershell
$env:FCG_API_BASE_URL = "https://<endereco-publico-da-plataforma>"
$env:FCG_ADMIN_PASSWORD = "<senha do administrador do ambiente alvo>"
.venv\Scripts\pytest borda -v
```

### Variáveis

| variável | obrigatória | o que é |
|---|---|---|
| `FCG_API_BASE_URL` | sim | endereço público da plataforma, **sem barra final** |
| `FCG_ADMIN_PASSWORD` | sim | senha do administrador semeado no ambiente alvo |
| `FCG_ADMIN_EMAIL` | não | endereço do administrador (padrão: `admin@fcg.com`) |
| `FCG_TIMEOUT_SAGA` | não | segundos de espera pelo desfecho da compra (padrão: `30`) |

> **A senha do administrador varia por ambiente.** Ela pertence ao ambiente alvo, não à máquina
> de quem executa: usar a de outro ambiente produz uma recusa de autenticação que se parece com
> defeito de autorização. Nenhuma senha é lida de arquivo nem fica versionada.

O endereço precisa ser o mesmo texto que a plataforma declara como emissor dos tokens — uma
barra final sobrando faz toda rota protegida recusar token válido.

## O que a suite cobre

`borda/` — o contrato externo, visto de fora:

- **`test_autorizacao.py`** — rota protegida sem token e caminho inexistente são barrados
  antes de chegar ao serviço; biblioteca de terceiro e criação de item de catálogo por usuário
  comum são recusadas pelo serviço.
- **`test_catalogo.py`** — cadastro aberto, coerência entre o emissor do token e o documento de
  descoberta, chaves de assinatura publicadas, listagem autenticada e paginação.
- **`test_saga.py`** — a compra ponta a ponta pelos dois desfechos: aprovada entra na
  biblioteca, recusada não entra.

Dois cuidados que o código mantém de propósito:

- **Espera com prazo declarado, nunca pausa fixa.** A compra é resolvida de forma assíncrona;
  o helper de espera distingue "não concluiu no prazo" (caminho de mensagem interrompido) de
  "concluiu com o desfecho errado" (regra de negócio). São defeitos diferentes.
- **Toda afirmação de ausência tem âncora positiva.** Um teste que diz "isto não está lá" prova
  antes, no mesmo caminho, que a consulta enxergaria o item se ele estivesse — do contrário uma
  consulta quebrada passaria por comportamento correto.

## Qualidade

```bash
.venv/Scripts/ruff check .
.venv/Scripts/ruff format --check .
```
