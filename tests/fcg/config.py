"""Configuracao lida do ambiente.

Nenhum valor tem padrao embutido para credencial ou endereco: um padrao silencioso
faria a suite passar apontando para o alvo errado, que e a falha mais cara possivel
num teste de aceitacao.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

VAR_BASE_URL = "FCG_API_BASE_URL"
VAR_ADMIN_SENHA = "FCG_ADMIN_PASSWORD"
VAR_ADMIN_EMAIL = "FCG_ADMIN_EMAIL"
VAR_TIMEOUT_SAGA = "FCG_TIMEOUT_SAGA"
VAR_CHAVE_ASSINATURA = "FCG_RSA_PRIVATE_KEY_PATH"
VAR_DESTINO_SSH = "FCG_CLUSTER_SSH"

# o administrador e semeado com endereco fixo pelo servico de identidade; so a
# senha varia por ambiente.
ADMIN_EMAIL_PADRAO = "admin@fcg.com"

# a saga converge em segundos quando o broker esta saudavel. o teto e folgado de
# proposito: ele existe para distinguir "nao completou" de "completou errado",
# nao para medir desempenho.
TIMEOUT_SAGA_PADRAO = 30.0

# teto de cada requisicao isolada. o caminho ate o backend passa por gateway,
# ligacao privada e descoberta de servico, entao o primeiro acesso e mais lento
# que os seguintes.
TIMEOUT_REQUISICAO = 30.0


class ChaveDeAssinaturaIndisponivelError(RuntimeError):
    """Chave privada do emissor nao esta ao alcance desta execucao.

    Nao e defeito da plataforma: e a suite rodando sem o material que permite
    forjar token. Os testes que dependem dela se pulam sozinhos.
    """


class ConfiguracaoAusenteError(RuntimeError):
    """Variavel de ambiente obrigatoria nao definida.

    Nomeia a variavel que falta: erro que nao diz qual chave falta obriga quem
    executa a ler o codigo para descobrir.
    """

    def __init__(self, variavel: str, para_que: str) -> None:
        super().__init__(f"variavel de ambiente {variavel} nao definida ou vazia — {para_que}.")
        self.variavel = variavel


@dataclass(frozen=True, slots=True)
class Config:
    """Endereco e credenciais do alvo sob teste."""

    base_url: str
    admin_email: str
    admin_senha: str
    timeout_saga: float
    caminho_chave_assinatura: Path | None
    destino_ssh: str | None

    @classmethod
    def do_ambiente(cls) -> Config:
        """Monta a configuracao a partir das variaveis de ambiente."""
        return cls(
            base_url=_normaliza_base_url(
                _obrigatoria(VAR_BASE_URL, "e o endereco publico da plataforma sob teste")
            ),
            admin_email=os.environ.get(VAR_ADMIN_EMAIL, "").strip() or ADMIN_EMAIL_PADRAO,
            admin_senha=_obrigatoria(
                VAR_ADMIN_SENHA,
                "e a senha do administrador semeado, que varia por ambiente",
            ),
            timeout_saga=_float_opcional(VAR_TIMEOUT_SAGA, TIMEOUT_SAGA_PADRAO),
            caminho_chave_assinatura=_caminho_opcional(VAR_CHAVE_ASSINATURA),
            destino_ssh=os.environ.get(VAR_DESTINO_SSH, "").strip() or None,
        )

    def chave_de_assinatura(self) -> str:
        """Le a chave privada do emissor, ou diz por que nao da para ler.

        A chave nao e versionada e roda entre ambientes: o caminho vem do
        ambiente e o conteudo nunca encosta no repositorio. Quem chama trata a
        ausencia como teste pulado, nao como falha — token forjado e um reforco
        da suite, nao o piso dela.
        """
        if self.caminho_chave_assinatura is None:
            raise ChaveDeAssinaturaIndisponivelError(
                f"{VAR_CHAVE_ASSINATURA} nao definida — sem ela nao ha como assinar "
                "os tokens forjados dos testes de recusa."
            )
        try:
            return self.caminho_chave_assinatura.read_text(encoding="utf-8")
        except OSError as erro:
            raise ChaveDeAssinaturaIndisponivelError(
                f"nao consegui ler a chave em {self.caminho_chave_assinatura}: {erro}"
            ) from erro


def _obrigatoria(variavel: str, para_que: str) -> str:
    valor = os.environ.get(variavel, "").strip()
    if not valor:
        raise ConfiguracaoAusenteError(variavel, para_que)
    return valor


def _caminho_opcional(variavel: str) -> Path | None:
    bruto = os.environ.get(variavel, "").strip()
    return Path(bruto).expanduser() if bruto else None


def _float_opcional(variavel: str, padrao: float) -> float:
    bruto = os.environ.get(variavel, "").strip()
    if not bruto:
        return padrao
    try:
        return float(bruto)
    except ValueError as erro:
        raise ConfiguracaoAusenteError(
            variavel, f"quando definida precisa ser um numero de segundos (veio {bruto!r})"
        ) from erro


def _normaliza_base_url(bruto: str) -> str:
    """Remove a barra final da base.

    O emissor que o gateway exige no token e o endereco *sem* barra final, e o
    endereco de invocacao vem *com* ela. Concatenar caminho sobre a variante
    errada produz barra dupla, que nao casa rota declarada — falha que aparece
    como 404 ou 401 em requisicao valida, longe da causa.
    """
    return bruto.rstrip("/")
