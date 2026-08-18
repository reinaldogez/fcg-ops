"""A biblioteca e servida pelo read model, e nao pelo banco do servico.

A biblioteca existe em dois lugares: no banco relacional, onde o credito e
gravado como fonte da verdade, e na tabela desnormalizada, escrita por um
consumidor de projecao. A leitura publica deveria vir da segunda. Como as duas
contem o mesmo dado quando tudo funciona, comparar o conteudo **nao** distingue
uma da outra — uma leitura que fosse ao relacional devolveria exatamente a mesma
resposta.

O que distingue e introduzir uma divergencia deliberada: um item escrito **so**
na projecao, que nao existe no relacional. Se ele aparece na resposta publica, a
leitura veio da projecao. Se nao aparece, veio do outro lado.

O item forjado e removido ao fim do teste, inclusive quando ele falha.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from typing import Final

import pytest

from conftest import Usuario
from fcg.cliente import ClienteApi, descreve
from fcg.cluster import Postgres
from fcg.leitura import Biblioteca

TABELA_RELACIONAL: Final = "itens_biblioteca"

# titulo improvavel de existir no catalogo, para a falha apontar a origem certa
# se ele aparecer onde nao devia.
NOME_DO_ITEM_FORJADO: Final = "Jogo que so existe no read model"


@pytest.fixture
def item_so_na_projecao(read_model: Biblioteca, usuario: Usuario) -> Iterator[str]:
    """Escreve na projecao um item ausente do relacional, e o remove ao fim.

    O identificador e sorteado: um jogo que nao esta no catalogo nem no banco do
    servico so pode chegar a resposta publica por um caminho.
    """
    jogo_id = str(uuid.uuid4())
    read_model.projeta(
        usuario.id,
        jogo_id,
        nomeJogo=NOME_DO_ITEM_FORJADO,
        preco=1.23,
        adquiridoEm="2026-01-01T00:00:00Z",
        pedidoId=str(uuid.uuid4()),
    )
    try:
        yield jogo_id
    finally:
        read_model.remove(usuario.id, jogo_id)


def test_leitura_da_biblioteca_vem_da_projecao(
    cliente_proprio: ClienteApi,
    usuario: Usuario,
    banco_catalog: Postgres,
    item_so_na_projecao: str,
) -> None:
    """Item presente so na projecao aparece na resposta publica.

    A ancora e a ausencia dele no banco relacional, verificada no mesmo teste:
    sem isso, o item poderia ter chegado pelos dois caminhos e a resposta nao
    diria qual foi usado.
    """
    no_relacional = banco_catalog.conta(
        TABELA_RELACIONAL, f"usuario_id='{usuario.id}' AND jogo_id='{item_so_na_projecao}'"
    )
    assert no_relacional == 0, (
        f"o item forjado {item_so_na_projecao} existe no banco relacional, entao "
        "encontra-lo na resposta nao prova de onde veio a leitura."
    )

    resposta = cliente_proprio.get(f"/api/biblioteca/{usuario.id}")
    assert resposta.status_code == 200, (
        f"nao consegui ler a biblioteca do titular.\n{descreve(resposta)}"
    )

    devolvidos = [item["jogoId"] for item in resposta.json()]
    assert item_so_na_projecao in devolvidos, (
        f"o item {item_so_na_projecao}, presente apenas na projecao, nao apareceu "
        f"na resposta publica. itens devolvidos: {devolvidos}\n"
        "  a leitura da biblioteca esta sendo servida pelo banco relacional, e "
        "nao pelo read model: a projecao vira enfeite, e a consistencia eventual "
        "que o desenho assume nao esta sendo exercitada."
    )


def test_projecao_e_o_relacional_concordam_sobre_a_biblioteca(
    usuario_comum: Usuario, banco_catalog: Postgres, read_model: Biblioteca
) -> None:
    """Os dois lados guardam o mesmo conjunto de jogos para o mesmo titular.

    Divergencia aqui e consistencia eventual que nao convergiu — projecao
    parada, evento perdido — e aparece como biblioteca incompleta para quem le,
    enquanto o dado esta correto na fonte da verdade.
    """
    na_projecao = {item["jogoId"] for item in read_model.itens_de(usuario_comum.id)}
    bruto = banco_catalog.consulta_escalar(
        f"SELECT coalesce(string_agg(jogo_id::text, ','), '') FROM {TABELA_RELACIONAL} "
        f"WHERE usuario_id='{usuario_comum.id}';"
    )
    no_relacional = {parte for parte in bruto.split(",") if parte}

    assert na_projecao == no_relacional, (
        "projecao e banco relacional discordam sobre a biblioteca de "
        f"{usuario_comum.id}.\n"
        f"  so na projecao: {sorted(na_projecao - no_relacional)}\n"
        f"  so no relacional: {sorted(no_relacional - na_projecao)}\n"
        "  itens so no relacional sao projecao que nao convergiu; itens so na "
        "projecao sao residuo de escrita direta ou evento reprocessado."
    )
