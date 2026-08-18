"""Entrega confiavel entre servicos: outbox de saida, inbox de entrada.

O servico nao publica no broker durante a transacao de negocio. Ele grava a
mensagem numa tabela, **no mesmo commit** que o dado, e um despachante entrega
depois. Do outro lado, o consumidor registra o que ja processou numa segunda
tabela. As duas juntas resolvem o problema que a mensageria sozinha nao resolve:
a mensagem nao se perde se o broker cair, e nao e processada duas vezes se
chegar repetida.

Nada disso aparece em rota nenhuma — e estado interno de dois bancos. Por isso os
testes vivem aqui, e nao na camada de borda.

O que cada teste afirma:

1. a compra converge com o outbox **vazio** — nenhuma mensagem ficou encalhada;
2. o inbox **cresce** quando um evento novo e consumido, e e esse crescimento
   que da sentido ao teste de deduplicacao, que afirma o contrario.

**O caso do broker parado** — mensagem acumulando no outbox enquanto ninguem
despacha — foi observado em campo e nao vira teste automatizado: exigiria
derrubar o broker no meio da suite, que e caro e afeta quem mais estiver usando
o ambiente.
"""

from __future__ import annotations

import pytest

from conftest import Jogo, Usuario
from fcg.cliente import ClienteApi
from fcg.cluster import Postgres
from fcg.config import Config
from fcg.saga import aguarda_desfecho

# tabelas do padrao, criadas pela biblioteca de mensageria do servico.
TABELA_OUTBOX = "outbox_message"
TABELA_INBOX = "inbox_state"


def faz_compra_aprovada(config: Config, cliente: ClienteApi, jogo: Jogo) -> None:
    """Compra e espera o desfecho, exigindo aprovacao.

    Os testes daqui precisam de um evento que **circulou de verdade**: sem a
    saga concluida, nao ha mensagem publicada nem consumida para observar.
    """
    resposta = cliente.post("/api/pedidos", {"jogoId": jogo.id})
    assert resposta.status_code == 202, (
        f"o pedido deveria ser aceito com 202 para gerar o evento.\n"
        f"  veio {resposta.status_code}: {resposta.text[:200]}"
    )
    pedido_id = str(resposta.json()["id"])
    desfecho = aguarda_desfecho(cliente, pedido_id, config.timeout_saga)
    assert desfecho.aprovado, (
        f"a compra terminou {desfecho.status!r}, e os testes de entrega dependem "
        "de um evento de pagamento aprovado."
    )


@pytest.mark.saga
def test_outbox_nao_deixa_mensagem_encalhada(
    config: Config,
    cliente_proprio: ClienteApi,
    usuario: Usuario,
    jogo_barato: Jogo,
    banco_catalog: Postgres,
) -> None:
    """Depois da compra convergir, nao sobra mensagem por despachar.

    A tabela de saida e transitoria por natureza: a mensagem entra no commit do
    negocio e sai quando o despachante confirma a entrega. Sobra permanente ali
    significa despachante parado ou broker inalcancavel — e o sintoma nao
    aparece na resposta da compra, que ja respondeu 202 com sucesso.
    """
    faz_compra_aprovada(config, cliente_proprio, jogo_barato)

    encalhadas = banco_catalog.conta(TABELA_OUTBOX)
    assert encalhadas == 0, (
        f"a compra convergiu mas {encalhadas} mensagem(ns) continuam em "
        f"{TABELA_OUTBOX}.\n"
        "  o dado de negocio foi gravado e o evento nao saiu: procure o "
        "despachante e o alcance do broker, nao a regra de negocio. o pedido "
        "aparece como concluido enquanto o resto do sistema nunca soube dele."
    )


@pytest.mark.saga
def test_inbox_registra_o_evento_consumido(
    config: Config,
    cliente_proprio: ClienteApi,
    usuario: Usuario,
    jogo_barato: Jogo,
    banco_catalog: Postgres,
) -> None:
    """Consumir um evento novo deixa registro na tabela de entrada.

    E a ancora positiva do teste de deduplicacao: la se afirma que o registro
    **nao** cresce numa reentrega, e sem provar antes que ele cresce numa
    entrega legitima, um inbox quebrado — que nunca registra nada — passaria por
    deduplicacao perfeita.
    """
    antes = banco_catalog.conta(TABELA_INBOX)

    faz_compra_aprovada(config, cliente_proprio, jogo_barato)

    depois = banco_catalog.conta(TABELA_INBOX)
    assert depois > antes, (
        f"a compra convergiu e {TABELA_INBOX} continua com {depois} registro(s).\n"
        "  o consumidor processou o evento sem anotar que o processou: numa "
        "reentrega ele processaria de novo, e a projecao duplicaria."
    )
