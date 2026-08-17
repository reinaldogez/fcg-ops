"""A compra ponta a ponta, pelos dois desfechos.

O pedido e aceito de imediato e resolvido depois. O que se verifica aqui e o
efeito observavel de cada desfecho: a compra aprovada passa a constar na
biblioteca do comprador, a recusada nao. Como a projecao e assincrona, um teste
que so afirmasse ausencia poderia ficar verde por ter olhado cedo demais — por
isso todo teste de ausencia aqui carrega uma ancora positiva no mesmo caminho.
"""

from __future__ import annotations

import pytest

from conftest import Jogo, Usuario
from fcg.cliente import ClienteApi, descreve, respondido_pelo_backend
from fcg.config import Config
from fcg.saga import aguarda_desfecho

MOTIVO_ACIMA_DO_LIMITE = "Valor acima do limite autorizado"

# a plataforma recusa a compra de um jogo que o titular ja possui.
STATUS_JOGO_JA_NA_BIBLIOTECA = 409


def itens_da_biblioteca(cliente: ClienteApi, usuario_id: str) -> list[dict]:
    """Le a biblioteca do titular, exigindo que a consulta tenha funcionado."""
    resposta = cliente.get(f"/api/biblioteca/{usuario_id}")
    assert resposta.status_code == 200, (
        f"nao consegui ler a biblioteca de {usuario_id}.\n{descreve(resposta)}"
    )
    return list(resposta.json())


def faz_pedido(cliente: ClienteApi, jogo: Jogo) -> str:
    """Envia o pedido e devolve o identificador, exigindo aceite imediato."""
    resposta = cliente.post("/api/pedidos", {"jogoId": jogo.id})
    assert resposta.status_code == 202, (
        f"o pedido de {jogo.titulo!r} deveria ser aceito com 202 para resolucao "
        f"posterior.\n{descreve(resposta)}"
    )
    corpo = resposta.json()
    assert corpo.get("status") == "Pendente", (
        f"o pedido deveria nascer pendente e veio {corpo.get('status')!r}.\n{descreve(resposta)}"
    )
    return str(corpo["id"])


@pytest.mark.saga
def test_compra_aprovada_entra_na_biblioteca(
    config: Config, cliente_proprio: ClienteApi, usuario: Usuario, jogo_barato: Jogo
) -> None:
    """Pedido dentro do limite e aprovado e projetado na biblioteca."""
    antes = itens_da_biblioteca(cliente_proprio, usuario.id)
    assert antes == [], (
        f"o usuario recem-criado ja tem {len(antes)} itens na biblioteca. "
        "a assercao de que a compra acrescentou um item depende de comecar vazio."
    )

    pedido_id = faz_pedido(cliente_proprio, jogo_barato)
    desfecho = aguarda_desfecho(cliente_proprio, pedido_id, config.timeout_saga)

    assert desfecho.aprovado, (
        f"o pedido de {jogo_barato.titulo!r} ({jogo_barato.preco:.2f}, dentro do "
        f"limite) terminou {desfecho.status!r}, motivo {desfecho.motivo_recusa!r}."
    )

    depois = itens_da_biblioteca(cliente_proprio, usuario.id)
    assert len(depois) == 1, (
        f"apos a compra aprovada a biblioteca deveria ter exatamente um item, "
        f"e tem {len(depois)}: {depois}"
    )
    assert depois[0]["jogoId"] == jogo_barato.id, (
        f"a biblioteca recebeu o jogo {depois[0]['jogoId']}, e o comprado foi {jogo_barato.id}."
    )


@pytest.mark.saga
def test_recusa_nao_projeta_no_read_model(
    config: Config,
    cliente_proprio: ClienteApi,
    usuario: Usuario,
    jogo_barato: Jogo,
    jogo_caro: Jogo,
) -> None:
    """Pedido acima do limite e recusado e nao chega a biblioteca.

    A ancora positiva e uma compra aprovada do mesmo usuario, feita antes: ela
    prova que esta consulta enxerga projecao quando ha uma. Sem isso, biblioteca
    vazia por consulta quebrada seria indistinguivel de recusa bem-sucedida.
    """
    ancora_id = faz_pedido(cliente_proprio, jogo_barato)
    ancora = aguarda_desfecho(cliente_proprio, ancora_id, config.timeout_saga)
    assert ancora.aprovado, (
        f"a compra usada como ancora terminou {ancora.status!r}. sem ela, a "
        "ausencia do item caro nao prova nada."
    )

    apos_ancora = itens_da_biblioteca(cliente_proprio, usuario.id)
    assert len(apos_ancora) == 1, (
        "a ancora foi aprovada mas nao apareceu na biblioteca: a consulta nao "
        f"enxerga projecao, entao ela nao pode testemunhar ausencia. itens: {apos_ancora}"
    )

    pedido_id = faz_pedido(cliente_proprio, jogo_caro)
    desfecho = aguarda_desfecho(cliente_proprio, pedido_id, config.timeout_saga)

    assert desfecho.rejeitado, (
        f"o pedido de {jogo_caro.titulo!r} ({jogo_caro.preco:.2f}, acima do "
        f"limite) terminou {desfecho.status!r} em vez de recusado."
    )
    assert desfecho.motivo_recusa == MOTIVO_ACIMA_DO_LIMITE, (
        f"a recusa veio com o motivo {desfecho.motivo_recusa!r}, e o esperado "
        f"para valor acima do limite e {MOTIVO_ACIMA_DO_LIMITE!r}."
    )

    depois = itens_da_biblioteca(cliente_proprio, usuario.id)
    assert len(depois) == 1, (
        f"a biblioteca deveria continuar com o unico item da ancora, e tem "
        f"{len(depois)}: a compra recusada foi projetada."
    )
    assert all(item["jogoId"] != jogo_caro.id for item in depois), (
        f"o jogo recusado {jogo_caro.titulo!r} aparece na biblioteca: {depois}"
    )


@pytest.mark.saga
def test_compra_do_mesmo_jogo_duas_vezes_e_recusada(
    config: Config, cliente_proprio: ClienteApi, usuario: Usuario, jogo_barato: Jogo
) -> None:
    """Comprar de novo o que ja esta na biblioteca e recusado com 409.

    A ancora positiva e a primeira compra ter sido aprovada e projetada: sem ela
    um 409 por outro motivo — pedido malformado, jogo inexistente — passaria por
    correto. O que se afirma aqui e a recusa *por posse*, e ela so tem sentido
    depois que a posse existe.
    """
    primeiro_id = faz_pedido(cliente_proprio, jogo_barato)
    primeiro = aguarda_desfecho(cliente_proprio, primeiro_id, config.timeout_saga)
    assert primeiro.aprovado, (
        f"a primeira compra de {jogo_barato.titulo!r} terminou {primeiro.status!r}, "
        f"motivo {primeiro.motivo_recusa!r}. sem posse estabelecida, a recusa da "
        "segunda nao prova nada."
    )

    na_biblioteca = itens_da_biblioteca(cliente_proprio, usuario.id)
    assert any(item["jogoId"] == jogo_barato.id for item in na_biblioteca), (
        "a primeira compra foi aprovada mas o jogo nao chegou a biblioteca, entao "
        f"a segunda tentativa nao encontra posse para recusar. itens: {na_biblioteca}"
    )

    # sem passar pelo helper: ele exige o 202 do caminho feliz, e o que se espera
    # aqui e justamente a recusa.
    repetido = cliente_proprio.post("/api/pedidos", {"jogoId": jogo_barato.id})

    assert repetido.status_code == STATUS_JOGO_JA_NA_BIBLIOTECA, (
        f"o segundo pedido de {jogo_barato.titulo!r}, ja na biblioteca do titular, "
        f"deveria ser recusado com {STATUS_JOGO_JA_NA_BIBLIOTECA}.\n{descreve(repetido)}\n"
        "  aceito com 202 significa compra duplicada: o titular paga duas vezes "
        "pelo mesmo jogo."
    )
    assert respondido_pelo_backend(repetido), (
        "a recusa da compra duplicada veio da borda, nao do servico — entao ela "
        "nao prova que a regra de posse foi aplicada.\n"
        f"{descreve(repetido)}"
    )
