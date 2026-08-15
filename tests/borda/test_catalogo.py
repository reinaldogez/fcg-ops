"""O contrato publico de identidade e catalogo.

O emissor declarado no token, o anunciado no documento de descoberta e o
endereco publico da plataforma precisam ser o mesmo texto. Divergencia de um
caractere — uma barra final a mais — faz toda rota protegida recusar token
valido, e o sintoma nao aponta para a causa.
"""

from __future__ import annotations

import uuid

from conftest import (
    CAMINHO_DISCOVERY,
    CAMINHO_JWKS,
    SENHA_DESCARTAVEL,
    Jogo,
    decodifica_corpo_do_token,
    insiste_sob_limite_de_taxa,
)
from fcg.cliente import ClienteApi, descreve, respondido_pelo_backend
from fcg.config import Config


def test_cadastro_publico_chega_ao_servico(cliente_anonimo: ClienteApi) -> None:
    """A rota de cadastro e aberta e atendida pelo servico, nao pela borda."""
    email = f"e2e-cadastro-{uuid.uuid4().hex[:12]}@fcg.test"

    resposta = insiste_sob_limite_de_taxa(
        lambda: cliente_anonimo.post(
            "/api/usuarios",
            {"nome": "Cadastro E2E", "email": email, "senha": SENHA_DESCARTAVEL},
        )
    )

    assert resposta.status_code == 201, (
        f"cadastro publico deveria devolver 201.\n{descreve(resposta)}"
    )
    assert respondido_pelo_backend(resposta), (
        "o cadastro nao foi atendido pelo servico — a resposta veio da borda.\n"
        f"{descreve(resposta)}"
    )


def test_token_declara_o_emissor_esperado(config: Config, token_admin: str) -> None:
    """O emissor do token e exatamente o endereco publico, sem barra final."""
    corpo = decodifica_corpo_do_token(token_admin)
    emissor = corpo.get("iss")

    assert emissor == config.base_url, (
        f"o token declara emissor {emissor!r}, e o endereco publico e "
        f"{config.base_url!r}. os dois precisam coincidir caractere a caractere: "
        "uma barra final sobrando faz a borda recusar token valido em toda rota "
        "protegida."
    )


def test_descoberta_anuncia_o_mesmo_emissor(cliente_anonimo: ClienteApi, token_admin: str) -> None:
    """O documento de descoberta concorda com o token sobre quem emite."""
    resposta = cliente_anonimo.get(CAMINHO_DISCOVERY)

    assert resposta.status_code == 200, (
        f"o documento de descoberta deveria estar publicado.\n{descreve(resposta)}"
    )

    anunciado = resposta.json().get("issuer")
    do_token = decodifica_corpo_do_token(token_admin).get("iss")
    assert anunciado == do_token, (
        f"a descoberta anuncia o emissor {anunciado!r}, mas o token diz {do_token!r}. "
        "a validacao na borda compara os dois: divergencia recusa token legitimo."
    )


def test_chaves_publicadas_servem_para_verificar_assinatura(
    cliente_anonimo: ClienteApi,
) -> None:
    """Ha ao menos uma chave publicada, e ela e de assinatura assimetrica."""
    resposta = cliente_anonimo.get(CAMINHO_JWKS)

    assert resposta.status_code == 200, (
        f"o conjunto de chaves deveria estar publicado.\n{descreve(resposta)}"
    )

    chaves = resposta.json().get("keys", [])
    assert chaves, (
        "o conjunto de chaves veio vazio: sem chave publicada, ninguem verifica "
        f"a assinatura dos tokens.\n{descreve(resposta)}"
    )

    algoritmos = {chave.get("alg") for chave in chaves}
    assert "RS256" in algoritmos, (
        f"nenhuma chave de assinatura assimetrica publicada. algoritmos: {sorted(algoritmos)}"
    )


def test_catalogo_autenticado_traz_itens(cliente_usuario: ClienteApi) -> None:
    """Com token valido, a listagem e atendida pelo servico e nao vem vazia."""
    resposta = cliente_usuario.get("/api/jogos", params={"pagina": 1, "tamanhoPagina": 100})

    assert resposta.status_code == 200, (
        f"a listagem autenticada do catalogo deveria devolver 200.\n{descreve(resposta)}"
    )
    assert respondido_pelo_backend(resposta), (
        f"a listagem nao foi atendida pelo servico.\n{descreve(resposta)}"
    )
    assert resposta.json(), (
        "o catalogo respondeu vazio: os testes de compra dependem do catalogo "
        "semeado, entao isto invalida a suite inteira, nao so este teste."
    )


def test_paginacao_limita_o_tamanho_da_pagina(cliente_usuario: ClienteApi) -> None:
    """O tamanho de pagina pedido e respeitado."""
    tamanho = 3
    resposta = cliente_usuario.get("/api/jogos", params={"pagina": 1, "tamanhoPagina": tamanho})

    assert resposta.status_code == 200, (
        f"a listagem paginada deveria devolver 200.\n{descreve(resposta)}"
    )
    itens = resposta.json()
    assert 0 < len(itens) <= tamanho, (
        f"pedi pagina de {tamanho} itens e vieram {len(itens)}.\n{descreve(resposta)}"
    )


def test_catalogo_traz_item_acima_do_limite(jogo_caro: Jogo) -> None:
    """O catalogo semeado tem o item caro de que o ramo recusado depende.

    Falha explicita aqui em vez de deixar o teste da recusa falhar por timeout:
    catalogo sem item caro e problema de dado semeado, nao da saga.
    """
    assert jogo_caro.preco > 5000, (
        f"o item mais caro do catalogo custa {jogo_caro.preco:.2f}, dentro do "
        "limite de aprovacao. sem item acima do limite nao ha como exercitar a recusa."
    )
