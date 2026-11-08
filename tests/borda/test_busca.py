"""A busca do catalogo pela borda.

A busca le uma projecao do catalogo num indice proprio, e nao a fonte da
verdade. Sem o indice o servico sobe saudavel e so a busca responde
indisponivel: o defeito nao aparece no rollout, aparece no uso. Por isso a
busca tem teste proprio, e o modulo inteiro so roda no ambiente que tem o
indice. Nenhum teste aqui cria ou altera jogo: a busca e conferida contra o
catalogo semeado.
"""

from __future__ import annotations

import pytest

from conftest import Jogo
from fcg.cliente import ClienteApi, descreve, respondido_pelo_backend

pytestmark = pytest.mark.busca

CAMINHO_BUSCA = "/api/jogos/search"

# termo com erro de digitacao de proposito: uma busca exata devolveria vazio, e
# so a tolerancia a erro encontra o titulo semeado.
TERMO_COM_ERRO = "witcer"
TITULO_ESPERADO = "The Witcher 3: Wild Hunt"

# termo com erro que casa com varios jogos: o nome da desenvolvedora. os titulos
# esperados nao ficam escritos aqui, saem do proprio catalogo.
DESENVOLVEDORA = "FromSoftware"
TERMO_COM_VARIOS_RESULTADOS = "fromsoftwre"


def test_busca_tolera_erro_de_digitacao_e_ordena_por_relevancia(
    cliente_usuario: ClienteApi,
) -> None:
    """O termo com erro encontra o titulo certo, e o melhor casamento vem primeiro.

    Encontrar o titulo prova a tolerancia a erro; ele estar em primeiro e a
    relevancia nao crescer ao longo da resposta provam a ordenacao. A
    relevancia so e comparavel dentro da mesma resposta, entao e so isso que se
    compara.
    """
    resposta = cliente_usuario.get(CAMINHO_BUSCA, params={"q": TERMO_COM_ERRO})

    assert resposta.status_code == 200, (
        f"a busca por {TERMO_COM_ERRO!r} deveria devolver 200.\n{descreve(resposta)}\n"
        "  503 aqui e busca desligada ou indice fora do ar, nao termo sem resultado."
    )
    assert respondido_pelo_backend(resposta), (
        f"a busca nao foi atendida pelo servico.\n{descreve(resposta)}"
    )

    itens = resposta.json()
    assert itens, (
        f"a busca por {TERMO_COM_ERRO!r} veio vazia: o indice nao tem o catalogo "
        f"semeado, ou nao tolera o erro de digitacao.\n{descreve(resposta)}"
    )
    assert itens[0]["titulo"] == TITULO_ESPERADO, (
        f"o primeiro item da busca por {TERMO_COM_ERRO!r} e {itens[0]['titulo']!r}, "
        f"e deveria ser {TITULO_ESPERADO!r}.\n{descreve(resposta)}"
    )

    relevancias = [float(item["relevancia"]) for item in itens]
    assert relevancias == sorted(relevancias, reverse=True), (
        f"a relevancia cresce ao longo da resposta: {relevancias}. o melhor "
        f"casamento tem de vir primeiro.\n{descreve(resposta)}"
    )


def test_busca_com_varios_resultados_ordena_por_relevancia(
    cliente_usuario: ClienteApi, catalogo: list[Jogo]
) -> None:
    """Com varios resultados, a relevancia nunca cresce ao longo da resposta.

    O termo do teste do Witcher tem um resultado so, e uma lista de um item esta
    sempre ordenada: ali a ordem nao e provada. Aqui o termo casa com todos os
    jogos de uma desenvolvedora, e a resposta tem de trazer cada um deles, do
    melhor casamento para o pior.
    """
    esperados = {jogo.titulo for jogo in catalogo if jogo.desenvolvedora == DESENVOLVEDORA}
    assert len(esperados) >= 2, (
        f"o catalogo semeado tem {len(esperados)} jogo(s) ativo(s) da {DESENVOLVEDORA}: "
        "com menos de dois, a ordem da resposta nao prova nada. confira o seed do catalogo."
    )

    resposta = cliente_usuario.get(CAMINHO_BUSCA, params={"q": TERMO_COM_VARIOS_RESULTADOS})

    assert resposta.status_code == 200, (
        f"a busca por {TERMO_COM_VARIOS_RESULTADOS!r} deveria devolver 200.\n"
        f"{descreve(resposta)}\n"
        "  503 aqui e busca desligada ou indice fora do ar, nao termo sem resultado."
    )
    assert respondido_pelo_backend(resposta), (
        f"a busca nao foi atendida pelo servico.\n{descreve(resposta)}"
    )

    itens = resposta.json()
    assert len(itens) >= 2, (
        f"a busca por {TERMO_COM_VARIOS_RESULTADOS!r} trouxe {len(itens)} item(ns); "
        f"o catalogo tem {len(esperados)} da {DESENVOLVEDORA}.\n{descreve(resposta)}"
    )

    faltando = esperados - {item["titulo"] for item in itens}
    assert not faltando, (
        f"a busca por {TERMO_COM_VARIOS_RESULTADOS!r} nao trouxe {sorted(faltando)}, "
        f"que sao da {DESENVOLVEDORA} no catalogo.\n{descreve(resposta)}"
    )

    relevancias = [float(item["relevancia"]) for item in itens]
    assert relevancias == sorted(relevancias, reverse=True), (
        f"a relevancia cresce ao longo da resposta: {relevancias}. o melhor "
        f"casamento tem de vir primeiro.\n{descreve(resposta)}"
    )


def test_busca_sem_token_e_recusada(cliente_anonimo: ClienteApi) -> None:
    """A busca e rota protegida: sem token nao ha resultado."""
    resposta = cliente_anonimo.get(CAMINHO_BUSCA, params={"q": TERMO_COM_ERRO})

    assert resposta.status_code == 401, (
        f"a busca sem token deveria ser recusada com 401.\n{descreve(resposta)}"
    )


def test_busca_sem_termo_e_recusada_pelo_servico(cliente_usuario: ClienteApi) -> None:
    """Sem termo nao ha busca, e quem diz isso e o servico.

    A listagem ja cobre o caso sem termo; aceitar a busca vazia daria uma
    segunda listagem, com outra ordem. O 400 vir do servico prova que a recusa
    e regra do catalogo, e nao da borda.
    """
    resposta = cliente_usuario.get(CAMINHO_BUSCA)

    assert resposta.status_code == 400, (
        f"a busca sem termo deveria ser recusada com 400.\n{descreve(resposta)}"
    )
    assert respondido_pelo_backend(resposta), (
        f"a recusa da busca sem termo nao veio do servico.\n{descreve(resposta)}"
    )
