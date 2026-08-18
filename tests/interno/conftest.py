"""Fixtures da camada que observa o cluster por dentro.

O que distingue esta camada da de borda e o canal, nao o alvo: a plataforma e a
mesma, e as fixtures de `conftest.py` (token, catalogo, usuario) continuam
valendo. O que se acrescenta aqui e o acesso ao interior — e a decisao de pular,
em vez de falhar, quando esse acesso nao existe.
"""

from __future__ import annotations

import pytest

from fcg.cluster import (
    AcessoCluster,
    ClusterInacessivelError,
    Postgres,
    Redis,
    ServicoInterno,
)
from fcg.config import VAR_DESTINO_SSH, Config
from fcg.leitura import Biblioteca, ReadModelInacessivelError
from fcg.mensageria import Broker

# porta de no do catalog, fixada nos manifestos. e por ela que se alcanca o
# servico de dentro da instancia, sem atravessar a borda.
PORTA_DE_NO_DO_CATALOG = 30083


@pytest.fixture(scope="session")
def acesso_cluster(config: Config) -> AcessoCluster:
    """Canal ate o interior do cluster, ou o teste se pula.

    Pular e o comportamento certo aqui: a suite de borda roda de qualquer
    maquina, e exigir SSH dela transformaria falta de acesso em falha de
    plataforma.
    """
    if config.destino_ssh is None:
        pytest.skip(
            f"{VAR_DESTINO_SSH} nao definida — os testes internos precisam de um "
            "destino de ssh que alcance o cluster (ex.: ec2-user@<endereco>)."
        )

    acesso = AcessoCluster(destino_ssh=config.destino_ssh)
    try:
        acesso.confere_alcance()
    except ClusterInacessivelError as erro:
        pytest.skip(str(erro))
    return acesso


@pytest.fixture(scope="session")
def redis(acesso_cluster: AcessoCluster) -> Redis:
    """Cliente do Redis interno, para observar o cache por dentro."""
    return Redis(acesso=acesso_cluster)


@pytest.fixture(scope="session")
def catalog_interno(acesso_cluster: AcessoCluster) -> ServicoInterno:
    """O catalog pela porta de no, para medir tempo sem a internet no meio."""
    return ServicoInterno(acesso=acesso_cluster, porta=PORTA_DE_NO_DO_CATALOG)


@pytest.fixture(scope="session")
def banco_catalog(acesso_cluster: AcessoCluster) -> Postgres:
    """Banco do catalog, onde vivem as tabelas de outbox e inbox."""
    return Postgres(acesso=acesso_cluster, pod="postgres-catalog-0", banco="catalog")


@pytest.fixture(scope="session")
def broker(acesso_cluster: AcessoCluster) -> Broker:
    """Interface de administracao do broker, para capturar e reentregar."""
    return Broker(acesso=acesso_cluster)


@pytest.fixture(scope="session")
def read_model() -> Biblioteca:
    """Tabela do read model, ou o teste se pula.

    A tabela mora na nuvem e nao no cluster: o canal e a credencial de quem
    executa, nao o ssh. Sem ela, pular — credencial local ausente nao e defeito
    de plataforma.
    """
    biblioteca = Biblioteca()
    try:
        biblioteca.confere_alcance()
    except ReadModelInacessivelError as erro:
        pytest.skip(str(erro))
    return biblioteca
