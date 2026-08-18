"""Acesso ao broker pela interface de administracao.

Serve ao que so se prova mexendo na mensageria: capturar um evento real que ja
circulou e reentrega-lo, que e a unica forma honesta de exercitar deduplicacao.
Mensagem sintetica provaria o teste, nao o sistema — o envelope de verdade traz
o identificador, o tipo e os cabecalhos que o consumidor de fato inspeciona.

O broker nao e alcancavel do laptop: ele vive em rede privada, e quem chega nele
e a instancia. Por isso os comandos daqui passam pelo mesmo canal do
`cluster.py`.

A credencial sai do Secret do cluster e entra no `curl` por **arquivo de
configuracao na entrada padrao**, nunca por argumento: argumento aparece no `ps`
da instancia, e a senha do broker nao pode aparecer.
"""

from __future__ import annotations

import json
import shlex
from dataclasses import dataclass
from typing import Any, Final

from .cluster import AcessoCluster, ClusterInacessivelError

# o vhost padrao, codificado para caber em caminho de URL.
VHOST: Final = "%2F"

# devolve a mensagem a fila depois de espiar. sem isto, espiar consome — e a
# fila que se observa e justamente a que guarda o evento a reentregar.
MODO_ESPIAR: Final = "ack_requeue_true"


@dataclass(frozen=True, slots=True)
class Broker:
    """Fala com a interface de administracao do broker, pela instancia."""

    acesso: AcessoCluster

    def _curl(self, metodo: str, caminho: str, corpo: str | None = None) -> str:
        """Chama a interface de administracao com a credencial fora do argumento.

        O `curl --config -` le usuario e senha da entrada padrao; o shell remoto
        monta esse bloco a partir do Secret e do ConfigMap do proprio cluster.
        """
        namespace = self.acesso.namespace
        dados = f" --data {shlex.quote(corpo)}" if corpo else ""
        script = (
            f"U=$(kubectl -n {namespace} get secret catalog-secret"
            ' -o jsonpath="{.data.RabbitMq__Username}" | base64 -d); '
            f"S=$(kubectl -n {namespace} get secret catalog-secret"
            ' -o jsonpath="{.data.RabbitMq__Password}" | base64 -d); '
            f"H=$(kubectl -n {namespace} get configmap catalog-env"
            ' -o jsonpath="{.data.RabbitMq__Host}"); '
            f'printf \'user = "%s:%s"\\n\' "$U" "$S" | '
            f"curl -sS --config - -X {metodo} -H 'content-type: application/json'"
            f'{dados} "https://$H/api/{caminho}"'
        )
        return self.acesso.executa(script)

    def _json(self, metodo: str, caminho: str, corpo: object = None) -> Any:
        bruto = self._curl(metodo, caminho, json.dumps(corpo) if corpo is not None else None)
        if not bruto.strip():
            return None
        try:
            return json.loads(bruto)
        except ValueError as erro:
            raise ClusterInacessivelError(
                f"esperava JSON do broker e veio: {bruto[:200]!r}"
            ) from erro

    def filas(self) -> dict[str, dict[str, Any]]:
        """Estado de cada fila, indexado pelo nome."""
        return {fila["name"]: fila for fila in self._json("GET", "queues") or []}

    def profundidade(self, fila: str) -> int:
        """Mensagens acumuladas numa fila."""
        estado = self.filas().get(fila)
        if estado is None:
            raise ClusterInacessivelError(f"a fila {fila!r} nao existe no broker.")
        return int(estado.get("messages", 0))

    def espia(self, fila: str) -> dict[str, Any] | None:
        """Le uma mensagem sem consumi-la, devolvendo-a a fila.

        Devolve `None` quando a fila esta vazia — quem chama decide se isso e
        motivo para pular o teste ou para falhar.
        """
        mensagens = self._json(
            "POST",
            f"queues/{VHOST}/{fila}/get",
            {"count": 1, "ackmode": MODO_ESPIAR, "encoding": "auto"},
        )
        return mensagens[0] if mensagens else None

    def republica(self, exchange: str, envelope: dict[str, Any]) -> bool:
        """Reentrega um envelope capturado, preservando o identificador.

        Preservar o identificador e o ponto: e por ele que o consumidor
        reconhece a mensagem como ja processada. Devolve se o broker roteou a
        mensagem para alguma fila — sem roteamento, a reentrega nao aconteceu e
        qualquer conclusao sobre deduplicacao seria falsa.
        """
        conteudo = envelope["payload"]
        identificador = envelope.get("properties", {}).get("message_id")
        resposta = self._json(
            "POST",
            f"exchanges/{VHOST}/{exchange}/publish",
            {
                "properties": {
                    "message_id": identificador,
                    "content_type": "application/vnd.masstransit+json",
                },
                "routing_key": envelope.get("routing_key", ""),
                "payload": conteudo,
                "payload_encoding": "string",
            },
        )
        return bool((resposta or {}).get("routed"))


def evento_do_envelope(envelope: dict[str, Any]) -> dict[str, Any]:
    """Extrai o evento de dominio de dentro do envelope de transporte.

    O corpo que trafega e um envelope: identificador, tipo e cabecalhos por
    fora, e o evento em si no campo `message`.
    """
    try:
        corpo = json.loads(envelope["payload"])
        return dict(corpo["message"])
    except (KeyError, ValueError) as erro:
        raise ClusterInacessivelError(
            f"o envelope capturado nao tem o formato esperado: {erro}"
        ) from erro


def identificador_do_envelope(envelope: dict[str, Any]) -> str:
    """Identificador da mensagem, que e a chave da deduplicacao."""
    corpo = json.loads(envelope["payload"])
    identificador = corpo.get("messageId")
    if not identificador:
        raise ClusterInacessivelError("o envelope capturado nao traz messageId.")
    return str(identificador)
