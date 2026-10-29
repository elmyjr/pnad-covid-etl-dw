# =====================================================================
# Arquivo  : python/ponte_oracle_sqlserver.py
# Objetivo : copiar a staging do Oracle (STAGING.PNAD_COVID_PESSOA) para
#            o espelho do SQL Server (staging.pnad_covid_pessoa), mes a
#            mes, sem transformar, com conferencia de contagens e log
# Etapa    : E5 - Ponte Python
# Depende  : python/config.py; .env; oracle/01_ddl_staging.sql;
#            sqlserver/01_ddl_staging_log.sql (espelho e
#            etl.usp_registrar_log)
# Uso      : python python\ponte_oracle_sqlserver.py            (todos)
#            python python\ponte_oracle_sqlserver.py --mes 2020-05
# Obs      : Python so faz a ponte (D18): le do Oracle e grava no SQL
#            Server os mesmos valores, sem ler CSV nem transformar
#          : por mes, numa transacao: DELETE do mes no espelho + INSERT
#            em lotes (fast_executemany) + conferencia origem = destino;
#            reexecucao substitui o mes (D16)
#          : log em etl.log_execucao (no_processo = ponte_oracle_sqlserver),
#            gravado depois do COMMIT ou do ROLLBACK (D26)
# =====================================================================
"""Ponte Oracle -> SQL Server da staging PNAD COVID-19."""

from __future__ import annotations

import argparse
import logging
import re
import sys
import time
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime

import oracledb
import pyodbc
from config import (
    ErroConfiguracao,
    conectar_oracle,
    conectar_sqlserver,
    configurar_logging,
)

NO_PROCESSO = "ponte_oracle_sqlserver"
TAMANHO_LOTE_PADRAO = 50_000

# as 24 colunas do enunciado, na mesma ordem nos dois bancos
COLUNAS: tuple[str, ...] = (
    "NU_ANO", "NU_MES", "UF", "CO_MUNICIPIO", "COR_RACA", "SEXO", "IDADE",
    "ESCOLARIDADE", "FAIXA_RENDIMENTO", "ATENDIMENTO_SUS", "INTERNADO",
    "SINTOMA_FEBRE", "SINTOMA_TOSSE", "SINTOMA_DOR_GARGANTA",
    "SINTOMA_DIFICULDADE_RESPIRAR", "SINTOMA_DOR_CABECA", "SINTOMA_DOR_PEITO",
    "SINTOMA_NAUSEA", "SINTOMA_NARIZ", "SINTOMA_FADIGA", "SINTOMA_DOR_OLHOS",
    "SINTOMA_PERDA_CHEIRO_SABOR", "SINTOMA_DOR_MUSCULAR", "DT_CARGA",
)
LISTA_COLUNAS = ", ".join(COLUNAS)

SQL_ORA_MESES = """
SELECT nu_ano, nu_mes, COUNT(*)
  FROM pnad_covid_pessoa
 GROUP BY nu_ano, nu_mes
 ORDER BY nu_ano, nu_mes"""

SQL_ORA_CONTAR = "SELECT COUNT(*) FROM pnad_covid_pessoa WHERE nu_ano = :ano AND nu_mes = :mes"

SQL_ORA_LER = f"SELECT {LISTA_COLUNAS} FROM pnad_covid_pessoa WHERE nu_ano = :ano AND nu_mes = :mes"

SQL_SS_APAGAR = "DELETE FROM staging.pnad_covid_pessoa WHERE NU_ANO = ? AND NU_MES = ?"

SQL_SS_INSERIR = (
    f"INSERT INTO staging.pnad_covid_pessoa ({LISTA_COLUNAS}) "
    f"VALUES ({', '.join('?' * len(COLUNAS))})"
)

SQL_SS_CONTAR = "SELECT COUNT(*) FROM staging.pnad_covid_pessoa WHERE NU_ANO = ? AND NU_MES = ?"

SQL_SS_LOG = """
SET NOCOUNT ON;
DECLARE @id_log INT;
EXEC etl.usp_registrar_log
     @no_processo        = ?,
     @ds_referencia      = ?,
     @dt_inicio          = ?,
     @qt_linhas_lidas    = ?,
     @qt_linhas_gravadas = ?,
     @st_execucao        = ?,
     @ds_observacao      = ?,
     @id_log             = @id_log OUTPUT;
SELECT @id_log;"""

log = logging.getLogger("ponte")


class ErroPonte(Exception):
    """Regra da ponte violada (mes vazio, contagens diferentes)."""


@dataclass
class ResultadoMes:
    referencia: str
    lidas: int = 0
    gravadas: int = 0
    substituidas: int = 0
    status: str = "ERRO"
    observacao: str = ""
    id_log: int | None = None


def referencia(ano: int, mes: int) -> str:
    return f"{ano:04d}-{mes:02d}"


def ler_mes_argumento(texto: str) -> tuple[int, int]:
    """Converte 'AAAA-MM' em (ano, mes)."""
    if not re.fullmatch(r"\d{4}-\d{2}", texto) or not 1 <= int(texto[5:]) <= 12:
        raise argparse.ArgumentTypeError(f"mes invalido: {texto!r} (use AAAA-MM)")
    return int(texto[:4]), int(texto[5:])


# ---------------------------------------------------------------------
# Oracle
# ---------------------------------------------------------------------
def listar_meses_oracle(con_ora: oracledb.Connection) -> list[tuple[int, int, int]]:
    """Meses presentes na staging Oracle: (ano, mes, linhas)."""
    with con_ora.cursor() as cur:
        cur.execute(SQL_ORA_MESES)
        return [(int(a), int(m), int(q)) for a, m, q in cur.fetchall()]


def contar_oracle(con_ora: oracledb.Connection, ano: int, mes: int) -> int:
    with con_ora.cursor() as cur:
        cur.execute(SQL_ORA_CONTAR, ano=ano, mes=mes)
        return int(cur.fetchone()[0])


# ---------------------------------------------------------------------
# SQL Server
# ---------------------------------------------------------------------
def registrar_log(con_ss: pyodbc.Connection, dt_inicio: datetime, r: ResultadoMes) -> None:
    """Grava o log fora da transacao da carga (depois do COMMIT/ROLLBACK)."""
    with closing(con_ss.cursor()) as cur:
        cur.execute(
            SQL_SS_LOG, NO_PROCESSO, r.referencia, dt_inicio,
            r.lidas, r.gravadas, r.status, r.observacao[:4000],
        )
        r.id_log = cur.fetchone()[0] # type: ignore
    con_ss.commit()


def copiar_mes(
    con_ora: oracledb.Connection, con_ss: pyodbc.Connection, ano: int, mes: int, lote: int
) -> ResultadoMes:
    """Substitui o mes no espelho pela copia do Oracle, numa transacao."""
    r = ResultadoMes(referencia(ano, mes))
    dt_inicio = datetime.now().replace(microsecond=0)
    inicio = time.perf_counter()
    try:
        qt_origem = contar_oracle(con_ora, ano, mes)
        if qt_origem == 0:
            raise ErroPonte(f"nenhuma linha de {r.referencia} na staging Oracle")

        with con_ora.cursor() as cur_ora, closing(con_ss.cursor()) as cur_ss:
            cur_ss.fast_executemany = True

            cur_ss.execute(SQL_SS_APAGAR, ano, mes)
            r.substituidas = max(cur_ss.rowcount, 0)

            cur_ora.arraysize = lote
            cur_ora.prefetchrows = lote + 1
            cur_ora.execute(SQL_ORA_LER, ano=ano, mes=mes)
            qt_lotes = 0
            while True:
                linhas = cur_ora.fetchmany(lote)
                if not linhas:
                    break
                r.lidas += len(linhas)
                cur_ss.executemany(SQL_SS_INSERIR, linhas)
                qt_lotes += 1
                log.debug("%s: lote %d, %d linhas acumuladas", r.referencia, qt_lotes, r.lidas)

            cur_ss.execute(SQL_SS_CONTAR, ano, mes)
            qt_destino = int(cur_ss.fetchone()[0]) # type: ignore

        if not (qt_origem == r.lidas == qt_destino):
            raise ErroPonte(
                f"contagens diferentes em {r.referencia}: Oracle {qt_origem}, "
                f"lidas {r.lidas}, espelho {qt_destino}"
            )

        con_ss.commit()
        r.gravadas = qt_destino
        r.status = "SUCESSO"
        r.observacao = (
            f"Oracle {qt_origem} linhas = espelho {qt_destino}; substituidas "
            f"{r.substituidas} linhas do mes; {qt_lotes} lote(s) de ate {lote}; "
            f"{time.perf_counter() - inicio:.1f} s"
        )
    except Exception as exc:  # qualquer falha: ROLLBACK e log de ERRO  # noqa: BLE001
        con_ss.rollback()
        r.gravadas = 0
        r.status = "ERRO"
        r.observacao = f"ROLLBACK do mes {r.referencia}: {exc}"

    registrar_log(con_ss, dt_inicio, r)
    return r


def executar(meses: list[tuple[int, int]] | None = None, lote: int = TAMANHO_LOTE_PADRAO) -> list[ResultadoMes]:
    """Copia os meses pedidos (ou todos os do Oracle); para no primeiro ERRO."""
    resultados: list[ResultadoMes] = []
    with conectar_oracle() as con_ora, closing(conectar_sqlserver()) as con_ss:
        if not meses:
            meses = [(a, m) for a, m, _ in listar_meses_oracle(con_ora)]
        if not meses:
            r = ResultadoMes("todos", observacao="staging Oracle vazia: nada a copiar")
            registrar_log(con_ss, datetime.now().replace(microsecond=0), r)
            log.error("Ponte: %s (log id %s)", r.observacao, r.id_log)
            return [r]
        log.info("Ponte Oracle -> SQL Server: %s", ", ".join(referencia(a, m) for a, m in meses))

        for ano, mes in meses:
            r = copiar_mes(con_ora, con_ss, ano, mes, lote)
            resultados.append(r)
            nivel = logging.INFO if r.status == "SUCESSO" else logging.ERROR
            log.log(nivel, "%s: %s - lidas %d, gravadas %d (log id %s) - %s",
                    r.referencia, r.status, r.lidas, r.gravadas, r.id_log, r.observacao)
            if r.status == "ERRO":
                break
    return resultados


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ponte Oracle -> SQL Server (staging PNAD COVID-19)")
    parser.add_argument("--mes", type=ler_mes_argumento, action="append",
                        help="mes a copiar no formato AAAA-MM (pode repetir); sem ele, copia todos")
    parser.add_argument("--lote", type=int, default=TAMANHO_LOTE_PADRAO,
                        help=f"linhas por lote (padrao {TAMANHO_LOTE_PADRAO})")
    parser.add_argument("--debug", action="store_true", help="mostra o andamento de cada lote")
    args = parser.parse_args(argv)

    configurar_logging(logging.DEBUG if args.debug else logging.INFO)
    try:
        resultados = executar(args.mes, args.lote)
    except (ErroConfiguracao, ErroPonte, oracledb.Error, pyodbc.Error) as exc:
        log.error("Ponte interrompida: %s", exc)
        return 1

    ok = sum(1 for r in resultados if r.status == "SUCESSO")
    total = sum(r.gravadas for r in resultados)
    log.info("Resumo: %d de %d mes(es) com SUCESSO; %d linhas no espelho", ok, len(resultados), total)
    return 0 if ok == len(resultados) else 1

if __name__ == "__main__":
    sys.exit(main())
