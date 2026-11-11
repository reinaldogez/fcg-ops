"""Fixtures compartilhadas dos testes ponta a ponta.

Escopo por custo: o que e caro e imutavel nasce uma vez por sessao (token de
administrador, catalogo); o que precisa de isolamento nasce por teste (usuario
descartavel). Um usuario novo a cada teste e o que torna verdadeira a assercao
"a biblioteca foi de zero a um" sem depender do que rodou antes.
"""

from __future__ import annotations

import base64
import binascii
import json
import time
import uuid
from collections.abc import Callable, Iterator
from typing import Any, Final, NamedTuple

import pytest
import requests

from fcg.cliente import ClienteApi, descreve
from fcg.config import Config

# regra de aprovacao da plataforma: pedido acima deste valor e recusado.
LIMITE_APROVACAO: Final = 5000.0

# senha dos usuarios descartaveis. nao e segredo: a conta nasce e morre dentro
# da suite, e o valor precisa satisfazer a politica de complexidade do servico.
SENHA_DESCARTAVEL: Final = "SenhaE2E@2026"

# prazo para a plataforma inteira responder na abertura. o primeiro acesso
# atravessa borda, ligacao privada e descoberta de servico, e o cluster pode
# ainda estar subindo quando a suite comeca.
TIMEOUT_PRONTIDAO: Final = 120.0
INTERVALO_PRONTIDAO: Final = 3.0

CAMINHO_DISCOVERY: Final = "/.well-known/openid-configuration"
CAMINHO_JWKS: Final = "/.well-known/jwks.json"

# a plataforma limita a taxa de requisicoes por janela e nao informa quando
# reentrar — a resposta nao traz cabecalho de reentrada —, entao a espera aqui e
# cega por necessidade. um teste barrado por limite de taxa nao encontrou defeito
# nenhum: encontrou a propria pressa da suite.
STATUS_LIMITE_DE_TAXA: Final = 429
TENTATIVAS_SOB_LIMITE: Final = 7
ESPERA_INICIAL_SOB_LIMITE: Final = 2.0
# teto por espera: sem ele o dobro sucessivo passaria de um minuto parado numa
# unica tentativa, e o proprio prazo do teste venceria antes da ultima.
ESPERA_MAXIMA_SOB_LIMITE: Final = 15.0

# intervalo minimo entre dois cadastros. o limite da plataforma responde a carga
# acumulada numa janela, e nao a taxa instantanea: sob carga recente ele barra
# ate um par de requisicoes, enquanto em repouso deixa passar varias seguidas.
# espacar antes e mais barato que reagir depois, porque uma vez barrado o balde
# so se esvazia com o tempo; o preco sao alguns segundos por execucao.
INTERVALO_ENTRE_CADASTROS: Final = 12.0


# instante do ultimo cadastro feito por esta execucao, para espacar o seguinte.
# comeca no passado distante para que o primeiro nao espere.
_instante_ultimo_cadastro = float("-inf")


class Usuario(NamedTuple):
    """Usuario descartavel criado para um unico teste."""

    id: str
    email: str
    token: str


class Jogo(NamedTuple):
    """Item do catalogo, reduzido ao que os testes usam."""

    id: str
    titulo: str
    preco: float
    desenvolvedora: str | None = None


@pytest.fixture(scope="session")
def config() -> Config:
    """Endereco e credenciais do alvo, vindos do ambiente."""
    return Config.do_ambiente()


@pytest.fixture(scope="session")
def cliente_anonimo(config: Config) -> Iterator[ClienteApi]:
    """Cliente sem token, para as rotas abertas e para as recusas esperadas."""
    cliente = ClienteApi(config.base_url)
    yield cliente
    cliente.fecha()


@pytest.fixture(scope="session", autouse=True)
def plataforma_pronta(config: Config, cliente_anonimo: ClienteApi) -> None:
    """Espera a plataforma responder antes de deixar qualquer teste rodar.

    Sem isto, um cluster ainda subindo faz a suite inteira falhar com erros
    espalhados que parecem defeitos distintos. A sonda e o documento de
    descoberta: e rota aberta, entao prova o caminho ate o servico sem depender
    de credencial. Nao ha rota de saude publicada na borda.
    """
    limite = time.monotonic() + TIMEOUT_PRONTIDAO
    ultima_falha = "nenhuma tentativa registrada"

    while time.monotonic() < limite:
        try:
            resposta = cliente_anonimo.get(CAMINHO_DISCOVERY)
        except Exception as erro:  # noqa: BLE001 - qualquer falha de rede e "ainda nao pronto"
            ultima_falha = f"erro de conexao: {erro}"
        else:
            if resposta.status_code == 200:
                return
            ultima_falha = descreve(resposta)
        time.sleep(INTERVALO_PRONTIDAO)

    pytest.fail(
        f"a plataforma nao respondeu em {TIMEOUT_PRONTIDAO:.0f}s no endereco "
        f"{config.base_url}.\n  ultima tentativa: {ultima_falha}\n"
        "  a suite nao chegou a testar nada: confira o alvo e se o cluster esta de pe."
    )


@pytest.fixture(scope="session")
def token_admin(config: Config, cliente_anonimo: ClienteApi) -> str:
    """Token do administrador semeado.

    Escopo de sessao porque autenticar e caro e o administrador nao muda. A
    senha vem do ambiente: ela difere entre o ambiente local e o de nuvem, e a
    do lugar errado produz 401 que parece defeito de autorizacao.
    """
    resposta = insiste_sob_limite_de_taxa(
        lambda: cliente_anonimo.post(
            "/api/auth/login",
            {"email": config.admin_email, "senha": config.admin_senha},
        )
    )
    assert resposta.status_code == 200, (
        f"login do administrador {config.admin_email} falhou.\n{descreve(resposta)}\n"
        "  confira a senha do ambiente sob teste — ela nao e a mesma em todos os alvos."
    )
    return str(resposta.json()["accessToken"])


@pytest.fixture(scope="session")
def cliente_admin(config: Config, token_admin: str) -> Iterator[ClienteApi]:
    """Cliente autenticado como administrador."""
    cliente = ClienteApi(config.base_url, token=token_admin)
    yield cliente
    cliente.fecha()


@pytest.fixture(scope="session")
def usuario_comum(cliente_anonimo: ClienteApi) -> Usuario:
    """Um usuario comum reaproveitado por toda a sessao.

    Serve a quem so precisa de um token sem privilegio administrativo. Cadastrar
    e uma rota sujeita a limite de taxa, entao criar um por teste gastaria a
    cota sem nada em troca: estes testes nao dependem do estado da conta.
    """
    return cadastra_usuario(cliente_anonimo)


@pytest.fixture
def usuario(cliente_anonimo: ClienteApi) -> Usuario:
    """Usuario novo, exclusivo deste teste.

    Reservado a quem precisa de biblioteca virgem: e o que torna verdadeira a
    assercao de que a compra levou a colecao de zero a um.
    """
    return cadastra_usuario(cliente_anonimo)


def cadastra_usuario(cliente_anonimo: ClienteApi) -> Usuario:
    """Cria e autentica uma conta descartavel.

    O identificador sai do token, nao do corpo do cadastro: e o mesmo valor que
    a plataforma usa para decidir de quem e a biblioteca.
    """
    _espaca_cadastro()
    email = f"e2e-{uuid.uuid4().hex[:12]}@fcg.test"

    cadastro = insiste_sob_limite_de_taxa(
        lambda: cliente_anonimo.post(
            "/api/usuarios",
            {"nome": "Usuario E2E", "email": email, "senha": SENHA_DESCARTAVEL},
        )
    )
    assert cadastro.status_code == 201, (
        f"nao consegui cadastrar o usuario descartavel {email}.\n{descreve(cadastro)}"
    )

    login = insiste_sob_limite_de_taxa(
        lambda: cliente_anonimo.post(
            "/api/auth/login", {"email": email, "senha": SENHA_DESCARTAVEL}
        )
    )
    assert login.status_code == 200, (
        f"cadastrei {email} mas nao consegui autenticar.\n{descreve(login)}"
    )

    token = str(login.json()["accessToken"])
    return Usuario(id=identificador_do_token(token), email=email, token=token)


@pytest.fixture(scope="session")
def cliente_usuario(config: Config, usuario_comum: Usuario) -> Iterator[ClienteApi]:
    """Cliente autenticado sem privilegio administrativo."""
    cliente = ClienteApi(config.base_url, token=usuario_comum.token)
    yield cliente
    cliente.fecha()


@pytest.fixture
def cliente_proprio(config: Config, usuario: Usuario) -> Iterator[ClienteApi]:
    """Cliente do usuario exclusivo deste teste, de biblioteca virgem."""
    cliente = ClienteApi(config.base_url, token=usuario.token)
    yield cliente
    cliente.fecha()


@pytest.fixture(scope="session")
def catalogo(config: Config, token_admin: str) -> list[Jogo]:
    """Jogos ativos do catalogo semeado, lidos uma vez por sessao.

    So os ativos: um jogo desativado continua na listagem, mas nao pode ser
    comprado, e a saga escolhe o mais barato ou o mais caro olhando apenas o
    preco. Com um desativado na ponta, o pedido seria recusado por outro motivo
    e o teste acusaria a regra de aprovacao no lugar do dado.
    """
    cliente = ClienteApi(config.base_url, token=token_admin)
    try:
        resposta = cliente.get("/api/jogos", params={"pagina": 1, "tamanhoPagina": 100})
        assert resposta.status_code == 200, f"nao consegui listar o catalogo.\n{descreve(resposta)}"
        itens = resposta.json()
        sem_ativo = [item.get("titulo", item.get("id")) for item in itens if "ativo" not in item]
        assert not sem_ativo, (
            f"a listagem do catalogo nao traz o campo 'ativo' em {len(sem_ativo)} item(ns) "
            f"(ex.: {sem_ativo[:3]}). sem ele nao da para separar o jogo compravel do "
            f"desativado, e a suite nao supoe.\n{descreve(resposta)}"
        )
        return [
            Jogo(
                id=item["id"],
                titulo=item["titulo"],
                preco=float(item["preco"]),
                desenvolvedora=item.get("desenvolvedora"),
            )
            for item in itens
            if item["ativo"] is True
        ]
    finally:
        cliente.fecha()


@pytest.fixture(scope="session")
def jogo_barato(catalogo: list[Jogo]) -> Jogo:
    """Jogo dentro do limite, cujo pedido a plataforma aprova."""
    candidatos = [jogo for jogo in catalogo if jogo.preco <= LIMITE_APROVACAO]
    assert candidatos, (
        f"nenhum jogo com preco ate {LIMITE_APROVACAO:.2f} no catalogo "
        f"({len(catalogo)} itens). o ramo aprovado da saga depende do catalogo semeado."
    )
    return min(candidatos, key=lambda jogo: jogo.preco)


@pytest.fixture(scope="session")
def jogo_caro(catalogo: list[Jogo]) -> Jogo:
    """Jogo acima do limite, cujo pedido a plataforma recusa.

    Descoberto no catalogo em vez de criado: criar exigiria privilegio de
    administrador e deixaria residuo a cada execucao.
    """
    candidatos = [jogo for jogo in catalogo if jogo.preco > LIMITE_APROVACAO]
    assert candidatos, (
        f"nenhum jogo acima de {LIMITE_APROVACAO:.2f} no catalogo "
        f"({len(catalogo)} itens). o ramo recusado da saga depende de um item caro "
        "no catalogo semeado."
    )
    return max(candidatos, key=lambda jogo: jogo.preco)


def _espaca_cadastro() -> None:
    """Garante o intervalo minimo desde o cadastro anterior desta execucao."""
    global _instante_ultimo_cadastro
    desde_o_anterior = time.monotonic() - _instante_ultimo_cadastro
    if desde_o_anterior < INTERVALO_ENTRE_CADASTROS:
        time.sleep(INTERVALO_ENTRE_CADASTROS - desde_o_anterior)
    _instante_ultimo_cadastro = time.monotonic()


def insiste_sob_limite_de_taxa(
    envia: Callable[[], requests.Response],
) -> requests.Response:
    """Reenvia enquanto a plataforma responder com limite de taxa.

    A espera dobra a cada tentativa. Devolve a ultima resposta seja qual for:
    julgar o codigo continua sendo de quem chamou, e um limite de taxa que
    persiste ate o fim vira falha visivel em vez de espera infinita.
    """
    espera = ESPERA_INICIAL_SOB_LIMITE
    resposta = envia()
    for _ in range(TENTATIVAS_SOB_LIMITE - 1):
        if resposta.status_code != STATUS_LIMITE_DE_TAXA:
            return resposta
        time.sleep(espera)
        espera = min(espera * 2, ESPERA_MAXIMA_SOB_LIMITE)
        resposta = envia()
    return resposta


def identificador_do_token(token: str) -> str:
    """Le o identificador do titular no corpo do token.

    Sem validar assinatura de proposito: aqui o token e apenas o portador de um
    dado que o cadastro nao devolve. Quem valida assinatura e a borda, e os
    testes de autorizacao e que provam que ela valida.
    """
    corpo = decodifica_corpo_do_token(token)
    identificador = corpo.get("sub")
    assert identificador, f"o token nao traz o identificador do titular. campos: {sorted(corpo)}"
    return str(identificador)


def decodifica_corpo_do_token(token: str) -> dict[str, Any]:
    """Devolve as declaracoes do token, sem verificar a assinatura."""
    partes = token.split(".")
    assert len(partes) == 3, f"token nao tem as tres partes esperadas (tem {len(partes)})."
    bruto = partes[1]
    # o preenchimento e omitido na codificacao usada por tokens web.
    bruto += "=" * (-len(bruto) % 4)
    try:
        return dict(json.loads(base64.urlsafe_b64decode(bruto)))
    except (binascii.Error, ValueError) as erro:
        raise AssertionError(f"nao consegui decodificar o corpo do token: {erro}") from erro
