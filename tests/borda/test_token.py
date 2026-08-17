"""Token invalido e barrado na borda, antes de acordar o backend.

Os testes de `test_autorizacao.py` cobrem a *ausencia* de credencial. Aqui a
credencial existe e esta corrompida, que e o caso mais interessante: e a prova de
que a borda valida o token de fato, em vez de so exigir que o cabecalho esteja
preenchido.

Sao dois grupos, e a diferenca entre eles importa:

- **Assinatura adulterada** parte de um token legitimo e troca um caractere da
  assinatura. Nao precisa de chave: o corpo continua valido, entao a unica razao
  possivel para a recusa e a verificacao criptografica.
- **Prazo vencido e audiencia errada** sao tokens *bem assinados*, forjados com a
  chave do emissor, que diferem de um token aceito em exatamente uma clausula.
  E o que isola a clausula: um token recusado por assinatura invalida nao diria
  nada sobre `exp` nem sobre `aud`.

Os dois casos assinados dependem da chave privada, que e rotativa e nao entra no
repositorio: o caminho dela vem do ambiente e eles se pulam quando ela falta. O
teste de controle existe por causa disso — ele prova, antes dos outros dois, que
a chave em maos e mesmo a do emissor em uso.

Nos quatro, a afirmacao forte e a mesma — o 401 vem da borda, sem `Server`: o
authorizer barra sozinho, sem consumir o backend.
"""

from __future__ import annotations

import base64
import time
import uuid
from typing import Any

import jwt
import pytest
import requests

from conftest import decodifica_corpo_do_token
from fcg.cliente import ClienteApi, descreve, respondido_pelo_backend
from fcg.config import ChaveDeAssinaturaIndisponivelError, Config

# rota protegida usada como sonda. qualquer uma serve; esta e barata e o teste de
# ancora prova que ela responde 200 com token bom.
ROTA_PROTEGIDA = "/api/jogos"

# algoritmo do emissor. o mesmo que o documento de chaves publica, e o unico que
# a borda aceita — assinar com outro testaria a rejeicao do algoritmo, que e
# outro assunto.
ALGORITMO = "RS256"

AUDIENCIA_DE_OUTRO_SISTEMA = "outro-sistema"

# prazo no passado, com folga suficiente para nenhum desvio de relogio plausivel
# entre a suite e a borda deixar o token ainda valido.
FOLGA_DE_EXPIRACAO = 3600

# validade do token forjado que serve de controle: curta, mas folgada o bastante
# para atravessar a requisicao.
VALIDADE_DO_CONTROLE = 300


@pytest.fixture(scope="module")
def chave_de_assinatura(config: Config) -> str:
    """Chave privada do emissor, ou o teste se pula.

    Sem ela nao se forja token assinado — e forjar e o unico jeito de isolar a
    clausula que causou a recusa.
    """
    try:
        return config.chave_de_assinatura()
    except ChaveDeAssinaturaIndisponivelError as erro:
        pytest.skip(str(erro))


@pytest.fixture(scope="module")
def identificador_da_chave(token_admin: str) -> str:
    """O `kid` que o emissor poe no cabecalho dos tokens que assina.

    Lido do proprio token em vez de fixado aqui: e o valor que a borda usa para
    escolher a chave de verificacao, e fixa-lo faria a suite mentir no dia em que
    a chave rodasse.
    """
    cabecalho = jwt.get_unverified_header(token_admin)
    kid = cabecalho.get("kid")
    assert kid, (
        f"o token do emissor nao traz `kid` no cabecalho: {cabecalho}. sem ele nao "
        "da para forjar token que a borda consiga verificar."
    )
    return str(kid)


@pytest.fixture(scope="module")
def declaracoes_de_um_token_aceito(token_admin: str) -> dict[str, Any]:
    """Corpo de um token que a borda aceita, base dos tokens forjados.

    Forjar a partir do que ja funciona e o que garante que a unica diferenca
    entre o token de controle e o adulterado seja a clausula sob teste.
    """
    return decodifica_corpo_do_token(token_admin)


def forja(chave: str, kid: str, declaracoes: dict[str, Any], **alteracoes: Any) -> str:
    """Assina um token com as declaracoes dadas, alterando o que for pedido.

    O `kid` no cabecalho nao e detalhe: e por ele que a borda escolhe, entre as
    chaves publicadas, qual verifica a assinatura. Token sem `kid` e recusado com
    o mesmo 401 de um token adulterado, mesmo assinado pela chave certa — medido.

    O identificador e sempre novo: token forjado repetido poderia esbarrar em
    cache de credencial da borda e devolver o veredito da tentativa anterior.
    """
    agora = int(time.time())
    corpo = (
        declaracoes
        | {
            "nbf": agora,
            "exp": agora + VALIDADE_DO_CONTROLE,
            "jti": str(uuid.uuid4()),
        }
        | alteracoes
    )
    return jwt.encode(corpo, chave, algorithm=ALGORITMO, headers={"kid": kid})


def com_assinatura_adulterada(token: str) -> str:
    """Inverte um bit da assinatura, preservando o corpo.

    A adulteracao e feita sobre os **bytes** da assinatura, e nao sobre um
    caractere do texto codificado. O motivo e medido: o ultimo caractere de uma
    assinatura RSA em base64url carrega so 2 bits significativos, entao trocar
    uma letra por outra ali costuma decodificar para o mesmo byte — o token
    continua valido, a borda responde 200 e o teste passa a afirmar o contrario
    do que promete.
    """
    cabecalho, corpo, assinatura = token.split(".")
    bruto = bytearray(base64.urlsafe_b64decode(assinatura + "=" * (-len(assinatura) % 4)))
    bruto[0] ^= 0x01
    adulterada = base64.urlsafe_b64encode(bytes(bruto)).decode().rstrip("=")
    return f"{cabecalho}.{corpo}.{adulterada}"


def assinatura_em_bytes(token: str) -> bytes:
    """Assinatura decodificada, que e o que a verificacao de fato compara."""
    assinatura = token.split(".")[2]
    return base64.urlsafe_b64decode(assinatura + "=" * (-len(assinatura) % 4))


def resposta_com_token(config: Config, token: str) -> requests.Response:
    """Consulta a rota protegida com o token dado, num cliente descartavel."""
    cliente = ClienteApi(config.base_url, token=token)
    try:
        return cliente.get(ROTA_PROTEGIDA)
    finally:
        cliente.fecha()


def exige_recusa_na_borda(resposta: requests.Response, o_que_foi_adulterado: str) -> None:
    """Afirma 401 vindo da borda, com a mensagem apontando a causa provavel."""
    assert resposta.status_code == 401, (
        f"token com {o_que_foi_adulterado} deveria ser recusado com 401.\n"
        f"{descreve(resposta)}\n"
        "  200 aqui significa que a borda aceita token que nao validou: qualquer "
        "pessoa forja credencial."
    )
    assert not respondido_pelo_backend(resposta), (
        f"token com {o_que_foi_adulterado} foi recusado, mas quem respondeu foi o "
        "servico — entao ele atravessou a borda e so morreu no backend.\n"
        f"{descreve(resposta)}\n"
        "  o authorizer deveria barrar antes, sem consumir o servico."
    )


def test_token_valido_e_aceito_na_mesma_rota(cliente_usuario: ClienteApi) -> None:
    """Ancora dos testes de recusa: com token bom, a mesma rota responde 200.

    Sem isto, um 401 nos casos seguintes poderia significar rota quebrada,
    servico fora do ar ou credencial de ambiente errado — tudo indistinguivel de
    validacao funcionando.
    """
    resposta = cliente_usuario.get(ROTA_PROTEGIDA)

    assert resposta.status_code == 200, (
        f"a rota {ROTA_PROTEGIDA} deveria responder 200 com token valido, entao os "
        f"401 dos testes de token adulterado nao provam validacao.\n{descreve(resposta)}"
    )
    assert respondido_pelo_backend(resposta), (
        f"o token valido foi aceito mas quem respondeu foi a borda, nao o servico.\n"
        f"{descreve(resposta)}"
    )


def test_token_forjado_com_a_chave_do_emissor_e_aceito(
    config: Config,
    chave_de_assinatura: str,
    identificador_da_chave: str,
    declaracoes_de_um_token_aceito: dict[str, Any],
) -> None:
    """Controle dos dois testes seguintes: forjado sem adulterar, a borda aceita.

    E o que da sentido aos casos de `exp` e `aud`: prova que a chave em maos e a
    do emissor em uso e que a forja produz token valido. Sem este controle, um
    401 la nao distinguiria clausula recusada de chave errada — e chave rotativa
    torna esse engano provavel, nao hipotetico.
    """
    controle = forja(chave_de_assinatura, identificador_da_chave, declaracoes_de_um_token_aceito)

    resposta = resposta_com_token(config, controle)

    assert resposta.status_code == 200, (
        "a borda recusou um token forjado sem nenhuma adulteracao.\n"
        f"{descreve(resposta)}\n"
        "  a chave em maos provavelmente nao e a que o emissor usa hoje — ela e "
        "rotativa. os testes de prazo e audiencia nao valem enquanto este nao passar."
    )


def test_assinatura_adulterada_e_barrada_na_borda(config: Config, token_admin: str) -> None:
    """Um caractere trocado na assinatura invalida o token.

    O corpo permanece intacto e dentro do prazo: a recusa so pode vir da
    verificacao criptografica.
    """
    adulterado = com_assinatura_adulterada(token_admin)
    assert assinatura_em_bytes(adulterado) != assinatura_em_bytes(token_admin), (
        "a adulteracao nao mudou os bytes da assinatura, entao o token continua "
        "legitimo e o teste nao exercita recusa nenhuma."
    )

    exige_recusa_na_borda(resposta_com_token(config, adulterado), "a assinatura adulterada")


def test_token_expirado_e_barrado_na_borda(
    config: Config,
    chave_de_assinatura: str,
    identificador_da_chave: str,
    declaracoes_de_um_token_aceito: dict[str, Any],
) -> None:
    """Prazo no passado invalida o token, com assinatura legitima.

    Difere do token de controle so no `exp`: a assinatura confere, entao o que a
    borda recusou foi o prazo. O `nbf` acompanha o `exp` para o passado — deixado
    no presente, o token seria invalido por duas razoes ao mesmo tempo, e o teste
    voltaria a nao isolar clausula nenhuma.
    """
    agora = int(time.time())
    expirado = forja(
        chave_de_assinatura,
        identificador_da_chave,
        declaracoes_de_um_token_aceito,
        nbf=agora - FOLGA_DE_EXPIRACAO * 2,
        exp=agora - FOLGA_DE_EXPIRACAO,
    )

    exige_recusa_na_borda(resposta_com_token(config, expirado), "o prazo no passado")


def test_token_de_outra_audiencia_e_barrado_na_borda(
    config: Config,
    chave_de_assinatura: str,
    identificador_da_chave: str,
    declaracoes_de_um_token_aceito: dict[str, Any],
) -> None:
    """Token para outro destinatario nao serve nesta borda.

    Difere do controle so no `aud`, e a assinatura confere: e a audiencia
    declarada no authorizer que impede um token legitimo de outro sistema do
    mesmo emissor de valer aqui.
    """
    de_outro = forja(
        chave_de_assinatura,
        identificador_da_chave,
        declaracoes_de_um_token_aceito,
        aud=AUDIENCIA_DE_OUTRO_SISTEMA,
    )

    exige_recusa_na_borda(resposta_com_token(config, de_outro), "a audiencia de outro sistema")


@pytest.mark.parametrize(
    "malformado",
    [
        pytest.param("", id="vazio"),
        pytest.param("nao-e-um-token", id="sem-as-tres-partes"),
        pytest.param("a.b.c", id="tres-partes-sem-conteudo"),
    ],
)
def test_token_malformado_e_barrado_na_borda(config: Config, malformado: str) -> None:
    """Texto que nem chega a ser um token tambem morre na borda.

    Nao e o mesmo caso dos anteriores: aqui nao ha o que verificar
    criptograficamente, e o que se afirma e que a borda recusa em vez de
    encaminhar lixo ao servico.
    """
    exige_recusa_na_borda(resposta_com_token(config, malformado), f"o texto {malformado!r}")
