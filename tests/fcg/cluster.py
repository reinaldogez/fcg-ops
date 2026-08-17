"""Acesso ao interior do cluster, para o que a borda nao mostra.

A camada de borda enxerga o contrato publico; ha comportamento que so se observa
por dentro — o cache que serviu uma leitura, a fila que recebeu a mensagem, o
estado que um servico guardou. Este modulo e o canal para isso: um comando roda
na instancia por SSH, e de la alcanca o cluster por `kubectl`.

Dois cuidados que o codigo mantem de proposito:

- **Falta de acesso nao e falha de teste.** Sem SSH, sem `kubectl` ou sem o pod
  de pe, quem chama recebe `ClusterInacessivelError` e pula. A plataforma pode
  estar perfeita e a maquina de quem executa nao ter caminho ate ela — sao coisas
  diferentes, e confundi-las produz vermelho que nao aponta defeito nenhum.
- **A senha nunca aparece na linha de comando.** Ela e lida do Secret dentro do
  proprio pod e usada ali; `ps` na instancia nao a mostra, e ela nao entra em log
  de terminal.
"""

from __future__ import annotations

import shlex
import subprocess
from dataclasses import dataclass
from typing import Final

# prazo de um comando remoto. o caminho e laptop -> instancia -> API do cluster
# -> pod, e o primeiro comando da sessao paga a abertura do SSH.
TIMEOUT_COMANDO: Final = 60.0

NAMESPACE: Final = "fcg"


class ClusterInacessivelError(RuntimeError):
    """Nao ha caminho ate o interior do cluster a partir daqui.

    E ausencia de canal, nao defeito da plataforma: quem chama trata como teste
    pulado.
    """


@dataclass(frozen=True, slots=True)
class AcessoCluster:
    """Executa comandos no cluster, atraves da instancia que o hospeda."""

    destino_ssh: str
    namespace: str = NAMESPACE

    def executa(self, comando: str) -> str:
        """Roda um comando de shell na instancia e devolve a saida.

        O comando vai como texto para o shell remoto: quem monta a string e
        responsavel por citar o que vier de fora.
        """
        try:
            concluido = subprocess.run(
                [
                    "ssh",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "ConnectTimeout=20",
                    "-o",
                    "StrictHostKeyChecking=accept-new",
                    self.destino_ssh,
                    comando,
                ],
                capture_output=True,
                text=True,
                timeout=TIMEOUT_COMANDO,
                check=False,
            )
        except FileNotFoundError as erro:
            raise ClusterInacessivelError(f"cliente de ssh nao encontrado: {erro}") from erro
        except subprocess.TimeoutExpired as erro:
            raise ClusterInacessivelError(
                f"o comando no cluster nao respondeu em {TIMEOUT_COMANDO:.0f}s: {comando}"
            ) from erro

        if concluido.returncode != 0:
            raise ClusterInacessivelError(
                f"comando falhou no cluster ({concluido.returncode}): {comando}\n"
                f"  saida de erro: {concluido.stderr.strip() or '<vazia>'}"
            )
        return concluido.stdout.strip()

    def kubectl(self, argumentos: str) -> str:
        """Roda um `kubectl` ja apontado para o namespace da plataforma."""
        return self.executa(f"kubectl -n {self.namespace} {argumentos}")

    def confere_alcance(self) -> None:
        """Falha cedo, com mensagem util, se o canal nao estiver de pe."""
        try:
            self.kubectl("get namespace " + self.namespace + " -o name")
        except ClusterInacessivelError as erro:
            raise ClusterInacessivelError(
                f"sem acesso ao cluster em {self.destino_ssh}: {erro}"
            ) from erro


@dataclass(frozen=True, slots=True)
class Redis:
    """Consulta o Redis do cluster, de dentro do proprio pod.

    O Redis nao tem rota na borda — e interno por construcao —, entao a unica
    forma de observa-lo e por aqui.
    """

    acesso: AcessoCluster
    deployment: str = "deploy/redis"

    def comando(self, *argumentos: str) -> str:
        """Executa um comando do Redis e devolve a saida limpa.

        A senha sai do Secret dentro do pod e nunca transita pela linha de
        comando de quem chama.
        """
        interno = " ".join(shlex.quote(argumento) for argumento in argumentos)
        namespace = self.acesso.namespace
        script = (
            f"P=$(kubectl -n {namespace} get secret redis-secret"
            ' -o jsonpath="{.data.REDIS_PASSWORD}" | base64 -d); '
            f"kubectl -n {namespace} exec {self.deployment} --"
            f' redis-cli -a "$P" --no-auth-warning {interno}'
        )
        return self.acesso.executa(script).replace("\r", "").strip()

    def existe(self, chave: str) -> bool:
        return self.comando("EXISTS", chave) == "1"

    def ttl(self, chave: str) -> int:
        """Segundos restantes da chave; negativo quando nao ha prazo ou chave."""
        return int(self.comando("TTL", chave))

    def apaga(self, chave: str) -> None:
        self.comando("DEL", chave)

    def campo(self, chave: str, campo: str) -> str | None:
        """Le um campo de hash, que e como o cache do .NET guarda cada entrada.

        Cada entrada e um `hash` com `data`, `absexp` e `sldexp` — inclusive as
        que guardam um unico valor. Ler com `GET` devolve `WRONGTYPE`, e tratar
        esse erro como ausencia leva a conclusao errada sobre o cache.
        """
        valor = self.comando("HGET", chave, campo)
        return valor or None

    def acertos(self) -> int:
        """Total de leituras servidas pelo cache desde que o servidor subiu."""
        return self._estatistica("keyspace_hits")

    def faltas(self) -> int:
        """Total de leituras que nao encontraram a chave."""
        return self._estatistica("keyspace_misses")

    def _estatistica(self, nome: str) -> int:
        saida = self.comando("INFO", "stats")
        for linha in saida.splitlines():
            if linha.startswith(f"{nome}:"):
                return int(linha.split(":", 1)[1])
        raise ClusterInacessivelError(f"a estatistica {nome} nao veio no INFO do Redis.")
