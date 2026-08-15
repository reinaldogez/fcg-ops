"""Quem a borda deixa passar, e quem ela barra.

Dois codigos de recusa iguais podem ter origens opostas: a borda recusando antes
de acordar o backend, ou o backend recusando depois de receber. O cabecalho que
identifica o servidor separa os dois casos, e cada teste daqui afirma nao so o
codigo, mas de onde ele veio.
"""

from __future__ import annotations

import pytest

from conftest import Jogo, Usuario
from fcg.cliente import ClienteApi, descreve, respondido_pelo_backend

# as rotas que exigem token. e a tabela declarada na borda: se uma delas deixar
# de ser protegida, o teste correspondente falha aqui, e nao em producao.
ROTAS_PROTEGIDAS = [
    ("GET", "/api/usuarios"),
    ("GET", "/api/jogos"),
    ("GET", "/api/jogos/00000000-0000-0000-0000-000000000000"),
    ("GET", "/api/pedidos"),
    ("GET", "/api/pedidos/00000000-0000-0000-0000-000000000000"),
    ("GET", "/api/usuarios/00000000-0000-0000-0000-000000000000"),
    ("GET", "/api/admin/qualquer"),
    ("GET", "/api/biblioteca/00000000-0000-0000-0000-000000000000"),
]


@pytest.mark.parametrize(("metodo", "caminho"), ROTAS_PROTEGIDAS, ids=lambda v: str(v))
def test_rota_protegida_sem_token_e_barrada_na_borda(
    cliente_anonimo: ClienteApi, metodo: str, caminho: str
) -> None:
    """Sem credencial, a borda recusa sozinha, sem encaminhar ao servico."""
    resposta = cliente_anonimo.get(caminho)

    assert resposta.status_code == 401, (
        f"{metodo} {caminho} sem token deveria ser recusado com 401.\n{descreve(resposta)}"
    )
    assert not respondido_pelo_backend(resposta), (
        f"{metodo} {caminho} foi recusado, mas quem respondeu foi o servico — "
        "a requisicao atravessou a borda sem credencial.\n"
        f"{descreve(resposta)}"
    )


def test_caminho_inexistente_morre_na_borda(cliente_anonimo: ClienteApi) -> None:
    """Caminho nao declarado nao chega ao servico.

    Nao ha rota de captura: o que nao esta na tabela e recusado antes da rede
    privada, sem consumir o backend.
    """
    resposta = cliente_anonimo.get("/api/caminho-que-nao-existe")

    assert resposta.status_code == 404, (
        f"caminho nao declarado deveria dar 404.\n{descreve(resposta)}"
    )
    assert not respondido_pelo_backend(resposta), (
        f"o caminho inexistente chegou ao servico em vez de morrer na borda.\n{descreve(resposta)}"
    )


def test_biblioteca_de_terceiro_e_recusada(
    cliente_usuario: ClienteApi, usuario_comum: Usuario
) -> None:
    """Token valido nao da acesso a biblioteca de outra pessoa.

    A ancora positiva e a propria biblioteca do titular: se ela nao respondesse,
    um 403 no alheio poderia significar rota quebrada em vez de regra aplicada.
    """
    propria = cliente_usuario.get(f"/api/biblioteca/{usuario_comum.id}")
    assert propria.status_code == 200, (
        "o titular nao consegue ler a propria biblioteca, entao a recusa da "
        f"biblioteca alheia nao prova nada.\n{descreve(propria)}"
    )

    alheia = "11111111-1111-1111-1111-111111111111"
    resposta = cliente_usuario.get(f"/api/biblioteca/{alheia}")

    assert resposta.status_code == 403, (
        f"usuario comum deveria receber 403 na biblioteca de terceiro.\n{descreve(resposta)}"
    )
    assert respondido_pelo_backend(resposta), (
        "a recusa veio da borda, nao do servico — entao ela nao prova que a "
        "regra de dono foi aplicada.\n"
        f"{descreve(resposta)}"
    )


def test_usuario_comum_nao_cria_jogo(cliente_usuario: ClienteApi, jogo_barato: Jogo) -> None:
    """Criar item de catalogo e privilegio de administrador.

    A ancora positiva e a leitura do catalogo com o mesmo token: ela prova que o
    token e aceito e que a recusa e de privilegio, nao de autenticacao.
    """
    leitura = cliente_usuario.get("/api/jogos", params={"pagina": 1, "tamanhoPagina": 1})
    assert leitura.status_code == 200, (
        "o token do usuario comum nao le nem o catalogo, entao a recusa na "
        f"criacao nao distingue privilegio de autenticacao.\n{descreve(leitura)}"
    )

    resposta = cliente_usuario.post(
        "/api/jogos",
        {
            "titulo": "Jogo que nao deveria nascer",
            "preco": 10.0,
            # o sufixo de fuso e obrigatorio: sem ele o servico recusa com erro
            # interno, e a falha se confunde com defeito de autorizacao.
            "dataLancamento": "2026-01-01T00:00:00Z",
        },
    )

    assert resposta.status_code == 403, (
        f"usuario comum deveria receber 403 ao criar jogo.\n{descreve(resposta)}"
    )
    assert respondido_pelo_backend(resposta), (
        "a recusa veio da borda, nao do servico — a regra de privilegio nao foi "
        f"exercitada.\n{descreve(resposta)}"
    )
