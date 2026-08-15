"""Cliente HTTP da borda publica.

Uma unica peca monta endereco, injeta o token e formata a resposta para as
mensagens de falha. Requisicao solta espalhada pelos testes repete essas tres
coisas e diverge com o tempo.
"""

from __future__ import annotations

import json
from typing import Any

import requests

from .config import TIMEOUT_REQUISICAO

# corpo maior que isso vira ruido na mensagem de falha; o inicio ja identifica
# o erro na pratica.
LIMITE_CORPO_NA_MENSAGEM = 400


class ClienteApi:
    """Fala com a plataforma por uma base fixa, opcionalmente autenticado."""

    def __init__(self, base_url: str, token: str | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self._sessao = requests.Session()
        if token:
            self._sessao.headers["Authorization"] = f"Bearer {token}"

    def get(self, caminho: str, **kwargs: object) -> requests.Response:
        return self._envia("GET", caminho, **kwargs)

    def post(
        self, caminho: str, corpo: dict[str, Any] | None = None, **kwargs: object
    ) -> requests.Response:
        return self._envia("POST", caminho, json=corpo, **kwargs)

    def _envia(self, metodo: str, caminho: str, **kwargs: object) -> requests.Response:
        kwargs.setdefault("timeout", TIMEOUT_REQUISICAO)
        return self._sessao.request(metodo, f"{self.base_url}/{caminho.lstrip('/')}", **kwargs)

    def fecha(self) -> None:
        self._sessao.close()


def descreve(resposta: requests.Response) -> str:
    """Resume a resposta para a mensagem de uma assercao que falhou.

    Codigo de status sozinho nao diz o que veio, e e justamente o corpo que
    separa "regra de negocio recusou" de "o pedido estava malformado".
    """
    return (
        f"{resposta.request.method} {resposta.request.url} "
        f"-> {resposta.status_code}\n"
        f"  cabecalho Server: {resposta.headers.get('Server', '<ausente>')}\n"
        f"  corpo: {_corpo_curto(resposta)}"
    )


def respondido_pelo_backend(resposta: requests.Response) -> bool:
    """Diz se quem redigiu a resposta foi o servico, e nao a borda.

    O gateway responde sem o cabecalho de identificacao do servidor; o servico
    responde com ele. E o que separa dois codigos iguais de origens opostas —
    uma recusa na borda e uma recusa no backend tem o mesmo numero.
    """
    return "Server" in resposta.headers


def _corpo_curto(resposta: requests.Response) -> str:
    bruto = resposta.text
    if not bruto:
        return "<vazio>"
    try:
        formatado = json.dumps(resposta.json(), ensure_ascii=False)
    except ValueError:
        formatado = bruto
    if len(formatado) > LIMITE_CORPO_NA_MENSAGEM:
        return f"{formatado[:LIMITE_CORPO_NA_MENSAGEM]}... (truncado)"
    return formatado
