"""Espera pelo desfecho da saga de compra.

O pedido e aceito de imediato e resolvido depois, por mensageria. Quem verifica
precisa esperar — mas espera fixa esconde os dois defeitos que importam, que sao
diferentes entre si: nao concluir dentro do prazo e concluir com o desfecho
errado. O primeiro e caminho de mensagem interrompido; o segundo e regra de
negocio. Confundi-los manda o diagnostico para o lado errado.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Final

from .cliente import ClienteApi, descreve

STATUS_PENDENTE: Final = "Pendente"

# intervalo entre consultas. o desfecho observado leva segundos, entao meio
# segundo da resolucao suficiente sem inundar o servico de requisicoes.
INTERVALO_CONSULTA: Final = 0.5


class SagaNaoConcluiuError(AssertionError):
    """O pedido continuou pendente ate o fim do prazo.

    Herda de AssertionError para que a falha apareca como teste reprovado, e nao
    como erro de infraestrutura do proprio teste.
    """


@dataclass(frozen=True, slots=True)
class Desfecho:
    """Estado final de um pedido, depois que a saga parou de mexer nele."""

    pedido_id: str
    status: str
    motivo_recusa: str | None
    valor: float

    @property
    def aprovado(self) -> bool:
        return self.status == "Aprovado"

    @property
    def rejeitado(self) -> bool:
        return self.status == "Rejeitado"


def aguarda_desfecho(cliente: ClienteApi, pedido_id: str, timeout: float) -> Desfecho:
    """Consulta o pedido ate ele sair de pendente, ou estoura o prazo.

    Devolve o desfecho seja ele qual for: comparar aprovado contra rejeitado e
    responsabilidade de quem chama. Aqui so se garante que a saga terminou.
    """
    limite = time.monotonic() + timeout
    ultimo_status = STATUS_PENDENTE
    consultas = 0

    while time.monotonic() < limite:
        resposta = cliente.get(f"/api/pedidos/{pedido_id}")
        consultas += 1
        if resposta.status_code != 200:
            raise AssertionError(
                f"consulta ao pedido {pedido_id} falhou enquanto a saga corria.\n"
                f"{descreve(resposta)}"
            )

        corpo = resposta.json()
        ultimo_status = corpo.get("status", "<sem campo status>")
        if ultimo_status != STATUS_PENDENTE:
            return Desfecho(
                pedido_id=pedido_id,
                status=ultimo_status,
                motivo_recusa=corpo.get("motivoRecusa"),
                valor=float(corpo.get("valor", 0)),
            )

        time.sleep(INTERVALO_CONSULTA)

    raise SagaNaoConcluiuError(
        f"o pedido {pedido_id} nao concluiu em {timeout:.0f}s: continua "
        f"{ultimo_status!r} apos {consultas} consultas.\n"
        "  isto nao e desfecho errado — e saga que nao terminou. procure o "
        "caminho da mensagem (broker de pe, servico consumindo a fila), nao a "
        "regra de aprovacao."
    )
