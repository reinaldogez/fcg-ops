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

Na Fase 4 a camada que roda é a de borda: `pytest borda`, **34 testes**. Sem argumento, `pytest`
coleta também `interno/`, que é da Fase 3 e se pula sem caminho até o cluster (ver
[O que a suite cobre](#o-que-a-suite-cobre)). Dentro da borda, selecione pelo marcador:

- `-m saga` — só a compra ponta a ponta, que espera mensageria;
- `-m busca` — só os 4 testes da busca do catálogo, que existem **apenas onde há índice de
  busca** (a sessão de nuvem);
- `-m "not busca"` — os outros 30, para o ambiente local: sem domínio de busca o catálogo sobe
  saudável e responde `503` na busca, por desenho, e esses testes falhariam sem defeito nenhum.

### Variáveis

| variável | obrigatória | o que é |
|---|---|---|
| `FCG_API_BASE_URL` | sim | endereço público da plataforma, **sem barra final** |
| `FCG_ADMIN_PASSWORD` | sim | senha do administrador semeado no ambiente alvo |
| `FCG_ADMIN_EMAIL` | não | endereço do administrador (padrão: `admin@fcg.com`) |
| `FCG_TIMEOUT_SAGA` | não | segundos de espera pelo desfecho da compra (padrão: `30`) |
| `FCG_RSA_PRIVATE_KEY_PATH` | não | caminho da chave privada do emissor, para os testes que forjam token |
| `FCG_CLUSTER_SSH` | não | só da camada interna, que é da Fase 3: destino de SSH que alcançava o cluster; sem ela, a camada se pula |

> **A chave de assinatura é a do emissor do ambiente alvo.** No k3d e na sessão de nuvem ela é
> a mesma: o `init-secrets.sh` materializa no cluster a chave que está no disco da cópia de quem
> administra (`identity-rsa-private.pem`, fora do git), nos dois perfis. Apontar para outra chave
> faz o teste de controle falhar com essa mensagem — de propósito, porque sem ele os testes de
> prazo e audiência ficariam verdes sem provar nada. Sem a variável, esses testes se pulam:
> forjar token é reforço da suite, não o piso dela. A chave nunca é lida de dentro do
> repositório.

> **A senha do administrador varia por ambiente.** Ela pertence ao ambiente alvo, não à máquina
> de quem executa: usar a de outro ambiente produz uma recusa de autenticação que se parece com
> defeito de autorização. Nenhuma senha é lida de arquivo nem fica versionada.

O endereço precisa ser o mesmo texto que a plataforma declara como emissor dos tokens — uma
barra final sobrando faz toda rota protegida recusar token válido.

## O que a suite cobre

São duas camadas, e o que as separa é o **canal**, não o alvo: a plataforma é a mesma. A de
borda roda de qualquer máquina; a interna precisa de caminho até o cluster e **se pula** quando
ele não existe — falta de acesso não é defeito de plataforma.

**Na Fase 4 só a borda roda.** A camada interna chegava ao cluster por SSH, e esse caminho não
existe no cluster gerenciado; ela não foi portada e fica no repositório como registro do que
provou na Fase 3 (estado completo na tag `fase-3`).

A camada interna existe porque três mecanismos centrais do desenho — cache, entrega confiável e
read model — **não têm sintoma externo quando quebram**. Uma biblioteca servida pelo banco
errado, um evento processado duas vezes e um cache que nunca é lido devolvem, todos, respostas
idênticas às corretas.

`borda/` — o contrato externo, visto de fora (34 testes, 4 sob o marcador `busca`):

- **`test_autorizacao.py`** — rota protegida sem token e caminho inexistente são barrados
  antes de chegar ao serviço; biblioteca de terceiro e criação de item de catálogo por usuário
  comum são recusadas pelo serviço.
- **`test_catalogo.py`** — cadastro aberto, coerência entre o emissor do token e o documento de
  descoberta, chaves de assinatura publicadas, listagem autenticada e paginação — tamanho da
  página e avanço para a segunda, que é o que pega deslocamento ignorado.
- **`test_token.py`** — token corrompido é barrado na borda: assinatura adulterada, prazo
  vencido, audiência de outro sistema e texto malformado.
- **`test_saga.py`** — a compra ponta a ponta pelos dois desfechos: aprovada entra na
  biblioteca, recusada não entra; e a compra repetida do mesmo jogo é recusada com 409. Os dois
  jogos da compra saem só dos **ativos** do catálogo: um desativado continua na listagem e não
  pode ser comprado, e a recusa viria pelo motivo errado.
- **`test_busca.py`** — a busca do catálogo: termo com erro de digitação acha o título certo em
  primeiro; termo que casa com vários jogos traz todos, em relevância não crescente (com um
  resultado só a ordem não prova nada); sem token, 401 na borda; sem termo, 400 do serviço. Os
  títulos esperados saem do próprio catálogo, não ficam escritos no teste.

`interno/` — da Fase 3, o que só se observava de dentro do cluster, por SSH + `kubectl`:

- **`test_cache.py`** — o ciclo do cache-aside do catálogo: a leitura fria grava a entrada com
  prazo, a seguinte é servida por ela e custa metade do tempo, e a escrita no catálogo invalida
  o que estava cacheado.
- **`test_outbox.py`** — entrega confiável: depois da compra convergir não sobra mensagem por
  despachar, e o consumo de um evento novo deixa registro na tabela de entrada.
- **`test_idempotencia.py`** — um evento **real**, capturado do broker e reentregue com o mesmo
  identificador, não credita a biblioteca duas vezes.
- **`test_read_model.py`** — a leitura da biblioteca vem da projeção, provado por um item que
  existe só nela; e os dois lados concordam sobre o conteúdo.

Dois cuidados que o código mantém de propósito:

- **Espera com prazo declarado, nunca pausa fixa.** A compra é resolvida de forma assíncrona;
  o helper de espera distingue "não concluiu no prazo" (caminho de mensagem interrompido) de
  "concluiu com o desfecho errado" (regra de negócio). São defeitos diferentes.
- **Toda afirmação de ausência tem âncora positiva.** Um teste que diz "isto não está lá" prova
  antes, no mesmo caminho, que a consulta enxergaria o item se ele estivesse — do contrário uma
  consulta quebrada passaria por comportamento correto.
- **Recusa esperada anda com um controle que passa.** Onde o teste afirma que a plataforma
  recusa, existe antes um caso quase idêntico que ela aceita — o token forjado sem adulteração,
  a primeira compra aprovada. É ele que separa "a regra foi aplicada" de "nada disso funciona":
  sem o controle, um 401 por chave errada e um 401 por prazo vencido são o mesmo resultado.

- **O sinal escolhido é o que discrimina, não o mais óbvio.** No cache, o contador de *acertos*
  sobe igual na leitura fria e na quente — toda leitura consulta antes a versão do catálogo —,
  e quem se apoiar nele conclui que o cache não serve nada. O que separa os dois casos é o
  contador de **faltas**: `+1` na fria, `0` na quente. Medido antes de virar asserção.

**Latência mede-se pelo canal certo, ou não mede nada.** Pela borda, a leitura quente e a fria
são indistinguíveis — mediana de 0,076s contra 0,079s em 12 amostras, com rodadas em que a fria
sai *mais rápida*. Não é o cache que falha: é que o trajeto até o gateway custa ~70ms e a
economia do cache é de ~2ms, então o ganho afunda no ruído. Medida na Fase 3 de dentro da
instância, pela porta de nó, a mesma leitura quente custa **metade** da fria (≈2ms contra ≈4ms), com as faixas sem
sobreposição. É por isso que a asserção de tempo vive na camada interna, e não na de borda.

## Qualidade

```bash
.venv/Scripts/ruff check .
.venv/Scripts/ruff format --check .
```
