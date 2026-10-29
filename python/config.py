# =====================================================================
# Arquivo  : python/config.py
# Objetivo : ler o .env, configurar o logging e abrir as conexoes com o
#            Oracle (staging) e o SQL Server (espelho, DW e log);
#            executado sozinho, testa as duas conexoes
# Etapa    : E0 - Ambiente
# Depende  : .env na raiz do projeto (modelo: .env.example),
#            python/requirements.txt e ODBC Driver 18 for SQL Server
# Uso      : python python\config.py  (na raiz, com a .venv ativa)
# Obs      : Python so faz ponte e orquestracao (D18); credenciais so
#            no .env; oracledb em modo thin (sem Oracle Client)
# =====================================================================
"""Configuracao e conexoes do pipeline PNAD COVID-19."""

from __future__ import annotations

import logging
import os
import sys
from contextlib import closing
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

import oracledb
import pyodbc
from dotenv import load_dotenv

RAIZ_PROJETO: Path = Path(__file__).resolve().parent.parent
ARQUIVO_ENV: Path = RAIZ_PROJETO / ".env"
TIMEOUT_CONEXAO_S: int = 15
NOME_APLICACAO: str = "pnad_covid_etl"  # aparece nas sessoes dos dois bancos

log = logging.getLogger("config")


class ErroConfiguracao(Exception):
    """Variavel ausente ou invalida no .env, ou driver nao instalado."""


@dataclass(frozen=True)
class ConfigOracle:
    host: str
    porta: int
    servico: str
    usuario: str
    senha: str = field(repr=False)

    @property
    def dsn(self) -> str:
        return f"{self.host}:{self.porta}/{self.servico}"


@dataclass(frozen=True)
class ConfigSqlServer:
    host: str
    porta: int
    banco: str
    usuario: str
    senha: str = field(repr=False)
    driver: str
    confiar_certificado: bool


# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------
def configurar_logging(nivel: int = logging.INFO) -> None:
    """Formato unico de log para todos os scripts do pipeline."""
    logging.basicConfig(
        level=nivel,
        format="%(asctime)s %(levelname)-7s %(name)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )


# ---------------------------------------------------------------------
# Leitura do .env
# ---------------------------------------------------------------------
def _ler_variaveis(nomes: tuple[str, ...]) -> dict[str, str]:
    """Le as variaveis do .env; erro unico listando todas as ausentes."""
    if not ARQUIVO_ENV.is_file():
        raise ErroConfiguracao(
            f"Arquivo .env nao encontrado em {ARQUIVO_ENV} (copie o .env.example)"
        )
    load_dotenv(ARQUIVO_ENV, override=True)  # o .env prevalece

    valores = {nome: os.getenv(nome, "") for nome in nomes}
    ausentes = [nome for nome, valor in valores.items() if not valor.strip()]
    if ausentes:
        raise ErroConfiguracao(
            "Variaveis vazias ou ausentes no .env: " + ", ".join(ausentes)
        )
    return valores


def _inteiro(nome: str, valor: str) -> int:
    try:
        return int(valor)
    except ValueError as exc:
        raise ErroConfiguracao(f"{nome} deve ser um numero inteiro: {valor!r}") from exc


def _sim_nao(nome: str, valor: str) -> bool:
    valor = valor.strip().lower()
    if valor not in ("yes", "no"):
        raise ErroConfiguracao(f"{nome} deve ser yes ou no: {valor!r}")
    return valor == "yes"


@lru_cache(maxsize=1)
def config_oracle() -> ConfigOracle:
    v = _ler_variaveis(
        ("ORACLE_HOST", "ORACLE_PORT", "ORACLE_SERVICE", "ORACLE_USER", "ORACLE_PASSWORD")
    )
    return ConfigOracle(
        host=v["ORACLE_HOST"].strip(),
        porta=_inteiro("ORACLE_PORT", v["ORACLE_PORT"]),
        servico=v["ORACLE_SERVICE"].strip(),
        usuario=v["ORACLE_USER"].strip(),
        senha=v["ORACLE_PASSWORD"],
    )


@lru_cache(maxsize=1)
def config_sqlserver() -> ConfigSqlServer:
    v = _ler_variaveis(
        (
            "SQLSERVER_HOST", "SQLSERVER_PORT", "SQLSERVER_DATABASE", "SQLSERVER_USER",
            "SQLSERVER_PASSWORD", "SQLSERVER_DRIVER", "SQLSERVER_TRUST_CERT",
        )
    )
    return ConfigSqlServer(
        host=v["SQLSERVER_HOST"].strip(),
        porta=_inteiro("SQLSERVER_PORT", v["SQLSERVER_PORT"]),
        banco=v["SQLSERVER_DATABASE"].strip(),
        usuario=v["SQLSERVER_USER"].strip(),
        senha=v["SQLSERVER_PASSWORD"],
        driver=v["SQLSERVER_DRIVER"].strip(),
        confiar_certificado=_sim_nao("SQLSERVER_TRUST_CERT", v["SQLSERVER_TRUST_CERT"]),
    )


# ---------------------------------------------------------------------
# Conexoes
# ---------------------------------------------------------------------
def conectar_oracle() -> oracledb.Connection:
    """Conexao thin com o schema STAGING (sem autocommit)."""
    cfg = config_oracle()
    log.debug("Conectando no Oracle %s como %s", cfg.dsn, cfg.usuario)
    conexao = oracledb.connect(
        user=cfg.usuario,
        password=cfg.senha,
        dsn=cfg.dsn,
        tcp_connect_timeout=TIMEOUT_CONEXAO_S,
    )
    conexao.module = NOME_APLICACAO
    return conexao


def _texto_odbc(valor: str) -> str:
    """Protege o valor com chaves (aceita ; e } em senhas)."""
    return "{" + valor.replace("}", "}}") + "}"


def _string_conexao_sqlserver(cfg: ConfigSqlServer) -> str:
    partes = [
        f"DRIVER={_texto_odbc(cfg.driver)}",
        f"SERVER={cfg.host},{cfg.porta}",
        f"DATABASE={cfg.banco}",
        f"UID={cfg.usuario}",
        f"PWD={_texto_odbc(cfg.senha)}",
        "Encrypt=yes",
        f"TrustServerCertificate={'yes' if cfg.confiar_certificado else 'no'}",
        f"APP={NOME_APLICACAO}",
    ]
    return ";".join(partes) + ";"


def conectar_sqlserver(autocommit: bool = False) -> pyodbc.Connection:
    """Conexao ODBC com o db_pnad_covid. Fechar com contextlib.closing:
    o 'with' do pyodbc so faz commit/rollback, nao fecha a conexao."""
    cfg = config_sqlserver()
    if cfg.driver not in pyodbc.drivers():
        raise ErroConfiguracao(
            f"Driver ODBC '{cfg.driver}' nao instalado. Disponiveis: {pyodbc.drivers()}"
        )
    log.debug("Conectando no SQL Server %s,%s/%s como %s", cfg.host, cfg.porta, cfg.banco, cfg.usuario)
    return pyodbc.connect(
        _string_conexao_sqlserver(cfg),
        autocommit=autocommit,
        timeout=TIMEOUT_CONEXAO_S,  # timeout de login
    )


# ---------------------------------------------------------------------
# Teste das conexoes (execucao direta do arquivo)
# ---------------------------------------------------------------------
SQL_TESTE_ORACLE = """
SELECT SYS_CONTEXT('USERENV', 'CON_NAME')      AS pdb,
       USER                                    AS usuario,
       TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') AS agora,
       (SELECT MAX(id_log) FROM log_carga)     AS ultimo_log
  FROM dual"""

SQL_STAGING_POR_MES = """
SELECT nu_ano, nu_mes, COUNT(*) AS linhas
  FROM pnad_covid_pessoa
 GROUP BY nu_ano, nu_mes
 ORDER BY nu_ano, nu_mes"""

SQL_TESTE_SQLSERVER = """
SELECT DB_NAME()                                         AS banco,
       SUSER_SNAME()                                     AS login_conectado,
       CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(20)) AS versao,
       CAST(SERVERPROPERTY('Edition') AS VARCHAR(60))    AS edicao,
       (SELECT c.encrypt_option FROM sys.dm_exec_connections AS c
         WHERE c.session_id = @@SPID)                    AS criptografia,
       CONVERT(VARCHAR(33), SYSDATETIMEOFFSET(), 126)    AS agora"""

SQL_SCHEMAS = """
SELECT name FROM sys.schemas
 WHERE name IN ('staging', 'dw', 'etl')
 ORDER BY name"""


def testar_oracle() -> None:
    cfg = config_oracle()
    with conectar_oracle() as conexao, conexao.cursor() as cur:
        log.info("Oracle conectado em %s (servidor %s)", cfg.dsn, conexao.version)
        cur.execute(SQL_TESTE_ORACLE)
        pdb, usuario, agora, ultimo_log = cur.fetchone()
        log.info("Oracle: PDB=%s usuario=%s agora=%s ultimo LOG_CARGA=%s", pdb, usuario, agora, ultimo_log)
        cur.execute(SQL_STAGING_POR_MES)
        meses = cur.fetchall()
        if not meses:
            log.warning("Oracle: staging PNAD_COVID_PESSOA vazia")
        for ano, mes, linhas in meses:
            log.info("Oracle: staging %d/%02d = %d linhas", ano, mes, linhas)


def testar_sqlserver() -> None:
    cfg = config_sqlserver()
    with closing(conectar_sqlserver()) as conexao, closing(conexao.cursor()) as cur:
        log.info("SQL Server conectado em %s,%s (driver %s)", cfg.host, cfg.porta, cfg.driver)
        cur.execute(SQL_TESTE_SQLSERVER)
        banco, login, versao, edicao, cripto, agora = cur.fetchone()
        log.info("SQL Server: banco=%s login=%s versao=%s (%s)", banco, login, versao, edicao)
        log.info("SQL Server: criptografia=%s agora=%s", cripto, agora)
        cur.execute(SQL_SCHEMAS)
        schemas = [linha[0] for linha in cur.fetchall()]
        log.info("SQL Server: schemas do projeto = %s", ", ".join(schemas))
        if len(schemas) != 3:
            raise ErroConfiguracao(f"Esperados os schemas dw, etl e staging; encontrados {schemas}")


def main() -> int:
    configurar_logging()
    falhas = 0
    for nome, teste in (("Oracle", testar_oracle), ("SQL Server", testar_sqlserver)):
        try:
            teste()
        except (ErroConfiguracao, oracledb.Error, pyodbc.Error) as exc:
            falhas += 1
            log.error("Falha no teste do %s: %s", nome, exc)
    if falhas:
        log.error("Teste de conexoes: %d falha(s)", falhas)
        return 1
    log.info("Teste de conexoes: OK nos dois bancos")
    return 0


if __name__ == "__main__":
    sys.exit(main())
