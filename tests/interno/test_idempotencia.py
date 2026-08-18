"""Reentregar o mesmo evento nao produz efeito duas vezes.

A mensageria entrega **ao menos uma vez**: reentrega acontece por reinicio de
consumidor, por confirmacao perdida, por retentativa depois de falha parcial. Um
consumidor que credita a biblioteca a cada mensagem recebida creditaria duas
vezes o mesmo jogo. O que impede isso e o registro de entrada, que guarda o
identificador do que ja foi processado.

**O evento usado aqui e real.** Ele e capturado de uma fila do proprio broker —
um `PaymentProcessedEvent` que ja circulou e ja foi projetado — e republicado
com o mesmo identificador. Um evento sintetico provaria o teste e nao o sistema:
o envelope de verdade carrega o identificador, o tipo e os cabecalhos que o
consumidor inspeciona, e e a combinacao deles que dispara a deduplicacao.

"Nao duplicou" so significa alguma coisa se a mensagem tiver mesmo chegado de
volta ao consumidor. Por isso a afirmacao central e sustentada por tres ancoras,
todas verificadas no proprio teste:

- o item **ja estava projetado** antes da reentrega, senao nao havia o que
  duplicar;
- o broker **roteou** a mensagem reentregue;
- o **contador de recebimentos** do registro daquela mensagem subiu. Esta e a
  ancora forte: o consumidor anota cada chegada mesmo quando reconhece a
  mensagem e decide nao reprocessa-la, entao o contador subindo prova que a
  entrega aconteceu — e nao apenas que o exchange aceitou a publicacao.
"""

from __future__ import annotations

import time
from typing import Final

import pytest

from fcg.cluster import Postgres
from fcg.mensageria import Broker, evento_do_envelope, identificador_do_envelope

# fila que guarda uma copia dos eventos de pagamento sem consumi-los, porque o
# consumidor dela nao sobe no perfil de sessao usado pelos testes. e a origem
# conveniente de um envelope real ja processado pelo outro ramo do fanout.
FILA_DE_CAPTURA: Final = "payment-processed.fcg-notifications-fn"
EXCHANGE: Final = "payment-processed"

TABELA_INBOX: Final = "inbox_state"
TABELA_BIBLIOTECA: Final = "itens_biblioteca"

# folga para a reentrega atravessar broker, consumidor e banco. o caminho e o
# mesmo da entrega original, que a suite ja mede em segundos.
ESPERA_DA_REENTREGA: Final = 10.0


@pytest.mark.saga
def test_reentrega_do_mesmo_evento_nao_duplica_a_projecao(
    broker: Broker, banco_catalog: Postgres
) -> None:
    """O mesmo evento, entregue de novo, nao credita a biblioteca duas vezes."""
    envelope = broker.espia(FILA_DE_CAPTURA)
    if envelope is None:
        pytest.skip(
            f"a fila {FILA_DE_CAPTURA} esta vazia: sem evento real capturado nao "
            "ha o que reentregar. rode um teste de compra antes, no mesmo alvo."
        )

    evento = evento_do_envelope(envelope)
    identificador = identificador_do_envelope(envelope)
    usuario_id = evento["userId"]
    jogo_id = evento["gameId"]

    projetados_antes = banco_catalog.conta(
        TABELA_BIBLIOTECA, f"usuario_id='{usuario_id}' AND jogo_id='{jogo_id}'"
    )
    assert projetados_antes > 0, (
        f"o evento capturado ({identificador}) credita o jogo {jogo_id} para "
        f"{usuario_id}, e a biblioteca nao tem esse item.\n"
        "  o evento ainda nao foi processado, entao reentrega-lo testaria "
        "primeira entrega, e nao deduplicacao."
    )

    registros_antes = banco_catalog.conta(TABELA_INBOX, f"message_id='{identificador}'")
    if registros_antes == 0:
        pytest.skip(
            f"o evento {identificador} nao tem registro em {TABELA_INBOX}: ou nunca "
            "foi consumido por este servico, ou o registro ja passou pela limpeza "
            "de retencao. sem ele nao ha deduplicacao a exercitar."
        )
    recebimentos_antes = _recebimentos(banco_catalog, identificador)

    assert broker.republica(EXCHANGE, envelope), (
        f"o broker nao roteou a reentrega do evento {identificador} para fila "
        "nenhuma.\n"
        "  sem roteamento a mensagem nao chegou ao consumidor, e 'nao duplicou' "
        "nao prova deduplicacao — prova que nada foi entregue."
    )
    time.sleep(ESPERA_DA_REENTREGA)

    # ancora forte: o contador de recebimentos do proprio registro subiu. isto
    # prova que a mensagem chegou ao consumidor de novo — nao so ao exchange —,
    # que e a unica condicao sob a qual "nao duplicou" significa alguma coisa.
    recebimentos_depois = _recebimentos(banco_catalog, identificador)
    assert recebimentos_depois > recebimentos_antes, (
        f"o registro de {identificador} continua com {recebimentos_depois} "
        "recebimento(s) depois da reentrega.\n"
        "  a mensagem foi roteada mas nao chegou ao consumidor, entao a ausencia "
        "de duplicata nao prova deduplicacao: nada foi reprocessado porque nada "
        "foi recebido."
    )

    registros_depois = banco_catalog.conta(TABELA_INBOX, f"message_id='{identificador}'")
    assert registros_depois == registros_antes, (
        f"a reentrega criou registro novo em {TABELA_INBOX} para {identificador} "
        f"({registros_antes} -> {registros_depois}).\n"
        "  a mensagem foi tratada como nova em vez de reconhecida pelo "
        "identificador: a restricao de unicidade por (mensagem, consumidor) "
        "deixou de valer, e o consumidor reprocessou."
    )

    projetados_depois = banco_catalog.conta(
        TABELA_BIBLIOTECA, f"usuario_id='{usuario_id}' AND jogo_id='{jogo_id}'"
    )
    assert projetados_depois == projetados_antes, (
        f"a reentrega do evento {identificador} levou a biblioteca de "
        f"{projetados_antes} para {projetados_depois} item(ns) do jogo {jogo_id}.\n"
        "  o consumidor processou de novo um evento que ja tinha processado: o "
        "titular aparece com o mesmo jogo duas vezes, e uma reentrega qualquer "
        "do broker basta para produzir isso em producao."
    )


def _recebimentos(banco: Postgres, identificador: str) -> int:
    """Quantas vezes o registro daquela mensagem ja foi recebido.

    O consumidor anota cada chegada, mesmo quando reconhece a mensagem e nao a
    processa de novo — e por isso que este contador serve de ancora.
    """
    bruto = banco.consulta_escalar(
        f"SELECT coalesce(sum(receive_count), 0) FROM {TABELA_INBOX} "
        f"WHERE message_id='{identificador}';"
    )
    return int(bruto)
