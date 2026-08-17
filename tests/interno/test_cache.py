"""O cache-aside da leitura do catalogo, observado por dentro.

Pela borda o cache e invisivel: duas leituras devolvem corpos identicos e nenhum
cabecalho diz de onde veio a resposta. Medir latencia tampouco separa os casos —
o trajeto ate o gateway domina o tempo, e a leitura fria ja saiu mais rapida que
a quente em rodada medida. Um teste apoiado nisso seria intermitente.

O que separa os dois casos e o estado do proprio Redis, e ele so se alcanca de
dentro do cluster. Cada teste aqui afirma uma etapa do ciclo do cache-aside:

1. leitura com o cache frio **cria** a entrada, com prazo de validade;
2. leitura seguinte e **servida pela entrada**, e nao produz falta no Redis;
3. escrita no catalogo **invalida** o que estava cacheado.

A chave carrega a paginacao (`jogos:lista:v<versao>:p<pagina>:t<tamanho>`), o que
permite a cada teste usar um tamanho proprio e nao disputar entrada com os
demais — nem com quem estiver usando a plataforma ao lado.
"""

from __future__ import annotations

import time
from typing import Final

import pytest

from fcg.cliente import ClienteApi, descreve
from fcg.cluster import Redis

# prazo configurado para a entrada do catalogo, em segundos. e o teto declarado
# na decisao de cache; a assercao usa "nao passa disto", nao igualdade, porque o
# relogio corre entre a gravacao e a leitura do prazo.
TTL_ESPERADO: Final = 300

# campo onde o cache do .NET guarda o conteudo de cada entrada. cada entrada e um
# `hash` com `data`, `absexp` e `sldexp` — ate as que guardam um unico valor.
CAMPO_DE_CONTEUDO: Final = "data"

CHAVE_DA_VERSAO: Final = "jogos:versao"

# tamanhos de pagina reservados a estes testes, um por teste. usar um valor
# proprio evita que dois testes disputem a mesma entrada e que uma leitura feita
# fora da suite aqueca a entrada sob observacao.
TAMANHO_DA_ENTRADA_FRIA: Final = 61
TAMANHO_DO_ACERTO: Final = 62
TAMANHO_DA_INVALIDACAO: Final = 63


def versao_do_catalogo(redis: Redis) -> str:
    """Versao corrente das entradas do catalogo.

    A invalidacao nao apaga chave: ela incrementa esta versao, e as entradas
    antigas ficam orfas ate o prazo vencer. Sem ler isto, monta-se o nome de uma
    entrada que ninguem mais escreve, e o cache parece nao funcionar.
    """
    return redis.campo(CHAVE_DA_VERSAO, CAMPO_DE_CONTEUDO) or "0"


def chave_da_lista(redis: Redis, tamanho: int, pagina: int = 1) -> str:
    """Nome da entrada que cacheia uma pagina especifica da listagem."""
    return f"jogos:lista:v{versao_do_catalogo(redis)}:p{pagina}:t{tamanho}"


def le_catalogo(cliente: ClienteApi, tamanho: int, pagina: int = 1) -> None:
    """Faz a leitura publica que alimenta o cache, exigindo que ela funcione."""
    resposta = cliente.get("/api/jogos", params={"pagina": pagina, "tamanhoPagina": tamanho})
    assert resposta.status_code == 200, (
        f"a leitura do catalogo deveria devolver 200 para alimentar o cache.\n{descreve(resposta)}"
    )


@pytest.mark.cache
def test_leitura_fria_cria_a_entrada_no_cache(cliente_usuario: ClienteApi, redis: Redis) -> None:
    """Com o cache vazio, a leitura publica grava a entrada — com prazo.

    E a metade "escreve" do cache-aside. A ancora e a entrada nao existir antes:
    sem apagar primeiro, uma entrada deixada por outra leitura faria este teste
    passar sem que nada tivesse sido gravado agora.
    """
    chave = chave_da_lista(redis, TAMANHO_DA_ENTRADA_FRIA)
    redis.apaga(chave)
    assert not redis.existe(chave), (
        f"a entrada {chave} continua no cache depois de apagada — sem comecar "
        "vazia, este teste nao prova que a leitura a criou."
    )

    le_catalogo(cliente_usuario, TAMANHO_DA_ENTRADA_FRIA)

    assert redis.existe(chave), (
        f"a leitura do catalogo nao criou a entrada {chave} no cache.\n"
        "  ou o cache-aside nao esta ligado no servico, ou a leitura foi servida "
        "sem passar por ele — nos dois casos o Postgres atende toda requisicao."
    )
    prazo = redis.ttl(chave)
    assert 0 < prazo <= TTL_ESPERADO, (
        f"a entrada {chave} foi criada com prazo de {prazo}s, e o esperado e um "
        f"valor entre 1 e {TTL_ESPERADO}s.\n"
        "  prazo negativo significa entrada sem validade: ela nunca expira "
        "sozinha, e o catalogo pode servir dado velho indefinidamente."
    )

    redis.apaga(chave)


@pytest.mark.cache
def test_segunda_leitura_e_servida_pelo_cache(cliente_usuario: ClienteApi, redis: Redis) -> None:
    """Com a entrada quente, a leitura seguinte e servida por ela.

    E a metade "le" do cache-aside, e a afirmacao forte deste modulo: a leitura
    quente **nao** produz falta no Redis, e a fria produz. A fria que a antecede
    e a ancora — sem ela, "zero faltas" tambem seria o retrato de um servico que
    nem consulta o cache.

    O contador escolhido e o de faltas, e nao o de acertos, por medicao: os
    acertos sobem igual (`+2`) na leitura fria e na quente, porque toda leitura
    consulta antes a versao do catalogo. Quem comparar acertos ve o mesmo numero
    nos dois casos e conclui que o cache nao serve nada.
    """
    chave = chave_da_lista(redis, TAMANHO_DO_ACERTO)
    redis.apaga(chave)

    antes_da_fria = redis.faltas()
    le_catalogo(cliente_usuario, TAMANHO_DO_ACERTO)
    faltas_da_fria = redis.faltas() - antes_da_fria
    assert redis.existe(chave), (
        f"a leitura fria nao deixou a entrada {chave} no cache, entao a leitura "
        "seguinte nao teria como ser servida por ela."
    )
    assert faltas_da_fria > 0, (
        f"a leitura com o cache vazio nao somou falta nenhuma ({faltas_da_fria}): "
        "o servico nao chegou a procurar a entrada no Redis.\n"
        "  sem essa procura, a ausencia de faltas na leitura seguinte nao prova "
        "que o cache serviu — prova que ele nao e consultado."
    )

    antes_da_quente = redis.faltas()
    le_catalogo(cliente_usuario, TAMANHO_DO_ACERTO)
    faltas_da_quente = redis.faltas() - antes_da_quente

    assert faltas_da_quente == 0, (
        f"a leitura com a entrada {chave} quente somou {faltas_da_quente} falta(s), "
        f"e a fria somou {faltas_da_fria}: a entrada existe mas nao foi aproveitada.\n"
        "  o cache-aside grava e nao le — o Postgres continua atendendo toda "
        "requisicao, e o cache so acrescenta escrita."
    )


@pytest.mark.cache
def test_escrita_no_catalogo_invalida_o_que_estava_cacheado(
    cliente_admin: ClienteApi, cliente_usuario: ClienteApi, redis: Redis
) -> None:
    """Criar um jogo derruba a listagem cacheada.

    Sem isto o cache serviria por ate cinco minutos um catalogo que ja mudou. A
    invalidacao aqui nao apaga a entrada: ela incrementa a versao, e a entrada
    antiga fica orfa — o efeito observavel e que a chave *corrente* passa a ser
    outra, e a antiga deixa de ser consultada.
    """
    chave_antiga = chave_da_lista(redis, TAMANHO_DA_INVALIDACAO)
    le_catalogo(cliente_usuario, TAMANHO_DA_INVALIDACAO)
    assert redis.existe(chave_antiga), (
        f"a entrada {chave_antiga} nao foi criada, entao nao ha o que invalidar."
    )
    versao_antes = versao_do_catalogo(redis)

    criado = cliente_admin.post(
        "/api/jogos",
        {
            "titulo": f"Jogo de invalidacao {time.time_ns()}",
            "descricao": "item criado pela suite para exercitar a invalidacao do cache",
            "preco": 1.0,
            "desenvolvedora": "Suite E2E",
            # o sufixo de fuso e obrigatorio: sem ele o servico recusa com erro
            # interno, e a falha se confunde com defeito de autorizacao.
            "dataLancamento": "2026-01-01T00:00:00Z",
        },
    )
    assert criado.status_code == 201, (
        f"a criacao do jogo deveria devolver 201 para exercitar a invalidacao.\n{descreve(criado)}"
    )

    versao_depois = versao_do_catalogo(redis)
    assert versao_depois != versao_antes, (
        f"a versao do catalogo continua {versao_depois!r} depois da escrita.\n"
        "  a listagem cacheada nao foi invalidada: leituras vao servir o catalogo "
        f"anterior ate o prazo de {TTL_ESPERADO}s vencer, sem o item recem-criado."
    )

    chave_nova = chave_da_lista(redis, TAMANHO_DA_INVALIDACAO)
    assert chave_nova != chave_antiga, (
        "a versao mudou mas o nome da entrada nao acompanhou, entao a leitura "
        f"seguinte continuaria caindo em {chave_antiga}."
    )
    assert not redis.existe(chave_nova), (
        f"a entrada {chave_nova} ja existe logo apos a invalidacao, sem nenhuma "
        "leitura entre as duas: ela deveria nascer so na proxima leitura."
    )
