"""Fixtures da camada que observa o cluster por dentro.

O que distingue esta camada da de borda e o canal, nao o alvo: a plataforma e a
mesma, e as fixtures de `conftest.py` (token, catalogo, usuario) continuam
valendo. O que se acrescenta aqui e o acesso ao interior — e a decisao de pular,
em vez de falhar, quando esse acesso nao existe.
"""

from __future__ import annotations

import pytest

from fcg.cluster import AcessoCluster, ClusterInacessivelError, Redis
from fcg.config import VAR_DESTINO_SSH, Config


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
