"""Acesso ao read model, que mora fora do cluster.

A biblioteca do usuario e uma projecao: o crédito acontece no banco relacional do
servico e um consumidor separado escreve a versao desnormalizada no DynamoDB, de
onde a leitura publica passa a servir. Provar que a leitura vem *de la*, e nao do
relacional, exige olhar a tabela diretamente — e ela nao esta no cluster, esta na
nuvem.

O canal e a linha de comando da AWS, com a credencial de quem executa. Sem ela,
ou sem a tabela, quem chama recebe `ReadModelInacessivelError` e pula: falta de
credencial local nao e defeito de plataforma.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from typing import Any, Final

TIMEOUT_COMANDO: Final = 60.0

# nome da tabela do read model. e o mesmo em toda sessao: ela e permanente, ao
# contrario do broker e da funcao, que nascem e morrem por sessao.
TABELA_BIBLIOTECA: Final = "fcg-biblioteca"

PREFIXO_USUARIO: Final = "USER#"
PREFIXO_JOGO: Final = "JOGO#"


class ReadModelInacessivelError(RuntimeError):
    """Nao ha caminho ate a tabela do read model a partir daqui."""


@dataclass(frozen=True, slots=True)
class Biblioteca:
    """Le e escreve a projecao da biblioteca, direto na tabela."""

    tabela: str = TABELA_BIBLIOTECA

    def _aws(self, *argumentos: str) -> dict[str, Any]:
        try:
            concluido = subprocess.run(
                ["aws", "dynamodb", *argumentos, "--output", "json"],
                capture_output=True,
                text=True,
                timeout=TIMEOUT_COMANDO,
                check=False,
            )
        except FileNotFoundError as erro:
            raise ReadModelInacessivelError(f"linha de comando da AWS ausente: {erro}") from erro
        except subprocess.TimeoutExpired as erro:
            raise ReadModelInacessivelError(
                f"a consulta ao read model nao respondeu em {TIMEOUT_COMANDO:.0f}s"
            ) from erro

        if concluido.returncode != 0:
            raise ReadModelInacessivelError(
                f"consulta ao read model falhou ({concluido.returncode}):\n"
                f"  {concluido.stderr.strip() or '<sem mensagem>'}"
            )
        if not concluido.stdout.strip():
            return {}
        try:
            return dict(json.loads(concluido.stdout))
        except ValueError as erro:
            raise ReadModelInacessivelError(
                f"esperava JSON da AWS e veio: {concluido.stdout[:200]!r}"
            ) from erro

    def confere_alcance(self) -> None:
        """Falha cedo se a tabela nao existir ou a credencial nao servir."""
        descricao = self._aws("describe-table", "--table-name", self.tabela)
        estado = descricao.get("Table", {}).get("TableStatus")
        if estado != "ACTIVE":
            raise ReadModelInacessivelError(
                f"a tabela {self.tabela} esta {estado!r}, e nao ACTIVE."
            )

    def itens_de(self, usuario_id: str) -> list[dict[str, Any]]:
        """Itens projetados para um titular, lidos direto da tabela."""
        resposta = self._aws(
            "query",
            "--table-name",
            self.tabela,
            "--key-condition-expression",
            "PK = :pk",
            "--expression-attribute-values",
            json.dumps({":pk": {"S": f"{PREFIXO_USUARIO}{usuario_id}"}}),
        )
        return [_simplifica(item) for item in resposta.get("Items", [])]

    def projeta(self, usuario_id: str, jogo_id: str, **campos: Any) -> None:
        """Escreve um item na projecao, sem passar pelo caminho de evento.

        Serve para provar de onde vem a leitura: um item que existe **so** aqui,
        e nao no banco relacional, aparece na resposta publica apenas se ela for
        servida por esta tabela.

        O tipo de cada campo segue o do valor em Python — numero vira `N`, texto
        vira `S`. Nao e detalhe: o servico desserializa o item com o tipo que
        espera, e um preco gravado como texto derruba a leitura com erro
        interno, que se parece com defeito de rota.
        """
        item = {
            "PK": {"S": f"{PREFIXO_USUARIO}{usuario_id}"},
            "SK": {"S": f"{PREFIXO_JOGO}{jogo_id}"},
            "usuarioId": {"S": usuario_id},
            "jogoId": {"S": jogo_id},
            **{chave: _tipado(valor) for chave, valor in campos.items()},
        }
        self._aws("put-item", "--table-name", self.tabela, "--item", json.dumps(item))

    def remove(self, usuario_id: str, jogo_id: str) -> None:
        """Apaga um item da projecao, para o teste nao deixar residuo."""
        chave = {
            "PK": {"S": f"{PREFIXO_USUARIO}{usuario_id}"},
            "SK": {"S": f"{PREFIXO_JOGO}{jogo_id}"},
        }
        self._aws("delete-item", "--table-name", self.tabela, "--key", json.dumps(chave))


def _tipado(valor: Any) -> dict[str, str]:
    """Marca o valor com o tipo que o DynamoDB espera."""
    if isinstance(valor, bool):
        return {"BOOL": valor}  # type: ignore[dict-item]
    if isinstance(valor, int | float):
        return {"N": str(valor)}
    return {"S": str(valor)}


def _simplifica(item: dict[str, Any]) -> dict[str, Any]:
    """Reduz o item ao par nome/valor, tirando a marcacao de tipo do DynamoDB."""
    return {nome: next(iter(valor.values())) for nome, valor in item.items()}
