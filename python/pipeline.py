# =====================================================================
# Arquivo  : python/pipeline.py
# Objetivo : orquestrar o pipeline completo: carga de cada CSV no Oracle
#            (PKG_CARGA_PNAD.usp_carregar) -> ponte Oracle -> SQL Server
#            -> etl.usp_carregar_dw; imprime um resumo no final
# Etapa    : E8 - Carga completa
# Depende  : python/config.py, python/ponte_oracle_sqlserver.py, .env;
#            package Oracle (E2) e procedures do SQL Server (E3 a E7)
# Uso      : python python\pipeline.py                     (todos)
#            python python\pipeline.py --arquivo PNAD_COVID_062020.csv
# Obs      : Python so orquestra (D18): lista os nomes dos arquivos na
#            pasta data (nao le o conteudo); quem le o CSV e o Oracle
#          : so entram arquivos PNAD_COVID_MMAAAA.csv, em ordem
#            cronologica (TESTE_*.csv ficam de fora)
#          : status de cada arquivo lido no LOG_CARGA; arquivo com ERRO
#            para o pipeline; SUCESSO PARCIAL segue com aviso
#          : cada etapa grava o proprio log (LOG_CARGA no Oracle,
#            etl.log_execucao no SQL Server); saida 1 em qualquer ERRO
# =====================================================================
"""Pipeline PNAD COVID-19: Oracle -> ponte -> DW."""

from __future__ import annotations

import argparse
import logging
import re
import sys
import time
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

import oracledb
import ponte_oracle_sqlserver as ponte
import pyodbc
from config import (
    RAIZ_PROJETO,
    ErroConfiguracao,
    conectar_oracle,
    conectar_sqlserver,
    configurar_logging,
)

PASTA_DADOS: Path = RAIZ_PROJETO / "data"
PADRAO_ARQUIVO = re.compile(r"PNAD_COVID_(\d{2})(\d{4})\.csv")

SQL_ORA_ULTIMO_LOG = "SELECT NVL(MAX(id_log), 0) FROM log_carga"

SQL_ORA_LOG_ARQUIVO = """
SELECT id_log, st_execucao, qt_linhas_lidas, qt_linhas_gravadas, qt_linhas_rejeitadas,
       ROUND((dt_fim - dt_inicio) * 86400), ds_observacao
  FROM log_carga
 WHERE no_arquivo = :arquivo
   AND id_log > :id_antes
 ORDER BY id_log DESC
 FETCH FIRST 1 ROWS ONLY"""

SQL_SS_LOG_DW = """
SELECT TOP (1) id_log, st_execucao, qt_linhas_lidas, qt_linhas_gravadas, ds_observacao
  FROM etl.log_execucao
 WHERE no_processo = 'usp_carregar_dw'
 ORDER BY id_log DESC"""

log = logging.getLogger("pipeline")


class ErroPipeline(Exception):
    """Regra do pipeline violada (arquivo invalido, etapa com ERRO)."""


@dataclass
class ResultadoArquivo:
    arquivo: str
    ano: int
    mes: int
    status: str = "ERRO"
    lidas: int | None = None
    gravadas: int | None = None
    rejeitadas: int | None = None
    duracao_s: int | None = None
    observacao: str = ""
    id_log: int | None = None


# ---------------------------------------------------------------------
# Arquivos (so os nomes; o conteudo e lido pelo Oracle)
# ---------------------------------------------------------------------
def mes_do_arquivo(nome: str) -> tuple[int, int]:
    """PNAD_COVID_MMAAAA.csv -> (ano, mes)."""
    m = PADRAO_ARQUIVO.fullmatch(nome)
    if not m or not 1 <= int(m.group(1)) <= 12:
        raise ErroPipeline(f"nome fora do padrao PNAD_COVID_MMAAAA.csv: {nome}")
    return int(m.group(2)), int(m.group(1))


def listar_arquivos(nomes: list[str] | None) -> list[str]:
    """Arquivos pedidos ou todos os PNAD_COVID_*.csv da pasta data, em ordem cronologica."""
    if nomes:
        faltando = [n for n in nomes if not (PASTA_DADOS / n).is_file()]
        if faltando:
            raise ErroPipeline(f"arquivo(s) nao encontrado(s) em {PASTA_DADOS}: {', '.join(faltando)}")
        candidatos = nomes  # nome fora do padrao gera erro em mes_do_arquivo
    else:
        candidatos = []
        for caminho in PASTA_DADOS.glob("PNAD_COVID_*.csv"):
            if PADRAO_ARQUIVO.fullmatch(caminho.name):
                candidatos.append(caminho.name)
            else:
                log.warning("Ignorado (fora do padrao PNAD_COVID_MMAAAA.csv): %s", caminho.name)
    arquivos = sorted(set(candidatos), key=mes_do_arquivo)
    if not arquivos:
        raise ErroPipeline(f"nenhum arquivo PNAD_COVID_MMAAAA.csv em {PASTA_DADOS}")
    return arquivos


# ---------------------------------------------------------------------
# Etapa 1: carga no Oracle
# ---------------------------------------------------------------------
def carregar_arquivo_oracle(con_ora: oracledb.Connection, arquivo: str) -> ResultadoArquivo:
    """Chama PKG_CARGA_PNAD.usp_carregar e le o status no LOG_CARGA."""
    ano, mes = mes_do_arquivo(arquivo)
    r = ResultadoArquivo(arquivo, ano, mes)
    with con_ora.cursor() as cur:
        cur.execute(SQL_ORA_ULTIMO_LOG)
        id_antes = int(cur.fetchone()[0])
        try:
            cur.callproc("pkg_carga_pnad.usp_carregar", [arquivo])
        except oracledb.DatabaseError as exc:
            r.observacao = str(exc).splitlines()[0]  # o package ja gravou o ERRO no LOG_CARGA

        cur.execute(SQL_ORA_LOG_ARQUIVO, arquivo=arquivo, id_antes=id_antes)
        linha = cur.fetchone()
    if linha is None:
        r.observacao = r.observacao or "sem registro no LOG_CARGA"
        return r
    r.id_log, r.status, r.lidas, r.gravadas, r.rejeitadas, r.duracao_s, obs = linha
    r.observacao = obs or r.observacao
    return r


def etapa_oracle(arquivos: list[str], resultados: list[ResultadoArquivo]) -> None:
    """Carrega os arquivos em ordem; para no primeiro ERRO (resultados vao para a lista)."""
    with conectar_oracle() as con_ora:
        for arquivo in arquivos:
            log.info("Oracle: carregando %s ...", arquivo)
            r = carregar_arquivo_oracle(con_ora, arquivo)
            resultados.append(r)
            if r.status == "ERRO":
                log.error("Oracle: %s - ERRO (LOG_CARGA id %s): %s", arquivo, r.id_log, r.observacao)
                raise ErroPipeline(f"carga de {arquivo} terminou com ERRO; pipeline interrompido")
            nivel = logging.INFO if r.status == "SUCESSO" else logging.WARNING
            log.log(nivel, "Oracle: %s - %s - lidas %s, gravadas %s, rejeitadas %s, %s s (LOG_CARGA id %s)",
                    arquivo, r.status, r.lidas, r.gravadas, r.rejeitadas, r.duracao_s, r.id_log)


# ---------------------------------------------------------------------
# Etapa 2: ponte (ver ponte_oracle_sqlserver.py)
# ---------------------------------------------------------------------
def etapa_ponte(meses: list[tuple[int, int]], lote: int, resultados: list[ponte.ResultadoMes]) -> None:
    """Copia os meses carregados no Oracle; para no primeiro ERRO."""
    resultados.extend(ponte.executar(meses, lote))
    if any(r.status != "SUCESSO" for r in resultados) or len(resultados) < len(meses):
        raise ErroPipeline("ponte terminou com ERRO; pipeline interrompido")


# ---------------------------------------------------------------------
# Etapa 3: DW (etl.usp_carregar_dw)
# ---------------------------------------------------------------------
def _mensagem_sqlserver(texto: str) -> str:
    """Tira o prefixo '[01000] [Microsoft][ODBC Driver ...][SQL Server]'."""
    return re.sub(r"^(\[[^\]]*\]\s*)+", "", texto).strip()


def etapa_dw() -> tuple:
    """Executa a procedure principal e devolve a linha dela no etl.log_execucao."""
    with closing(conectar_sqlserver(autocommit=True)) as con_ss:
        erro: pyodbc.Error | None = None
        with closing(con_ss.cursor()) as cur:
            try:
                cur.execute("EXEC etl.usp_carregar_dw")
                while True:  # mensagens (PRINT) de cada etapa da procedure
                    for _, texto in cur.messages: # type: ignore
                        log.info("DW: %s", _mensagem_sqlserver(texto)) # type: ignore
                    if not cur.nextset():
                        break
            except pyodbc.Error as exc:
                erro = exc
        with closing(con_ss.cursor()) as cur:
            cur.execute(SQL_SS_LOG_DW)
            linha = cur.fetchone()
    if erro is not None or linha is None or linha[1] != "SUCESSO":
        detalhe = linha[4] if linha else str(erro)
        log.error("DW: ERRO - %s", detalhe)
        raise ErroPipeline("usp_carregar_dw terminou com ERRO; pipeline interrompido")
    return tuple(linha)


# ---------------------------------------------------------------------
# Resumo e execucao
# ---------------------------------------------------------------------
def imprimir_resumo(oracle: list[ResultadoArquivo], pontes: list[ponte.ResultadoMes],
                    dw: tuple | None, inicio: float) -> None:
    log.info("=" * 78)
    log.info("RESUMO DO PIPELINE (%.0f s)", time.perf_counter() - inicio)
    for r in oracle:
        log.info("  Oracle  %-24s %-15s lidas %8s  gravadas %8s  rejeitadas %s",
                 r.arquivo, r.status, r.lidas, r.gravadas, r.rejeitadas)
    for p in pontes:
        log.info("  Ponte   %-24s %-15s lidas %8s  gravadas %8s", p.referencia, p.status, p.lidas, p.gravadas)
    if dw:
        log.info("  DW      %-24s %-15s lidas %8s  gravadas %8s  (log id %s)",
                 "usp_carregar_dw", dw[1], dw[2], dw[3], dw[0])
        log.info("  DW      %s", dw[4])
    log.info("=" * 78)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Pipeline PNAD COVID-19: Oracle -> ponte -> DW")
    parser.add_argument("--arquivo", action="append",
                        help="arquivo da pasta data (pode repetir); sem ele, todos os PNAD_COVID_*.csv")
    parser.add_argument("--lote", type=int, default=ponte.TAMANHO_LOTE_PADRAO,
                        help=f"linhas por lote na ponte (padrao {ponte.TAMANHO_LOTE_PADRAO})")
    parser.add_argument("--debug", action="store_true", help="mais detalhes no log")
    args = parser.parse_args(argv)

    configurar_logging(logging.DEBUG if args.debug else logging.INFO)
    inicio = time.perf_counter()
    oracle: list[ResultadoArquivo] = []
    pontes: list[ponte.ResultadoMes] = []
    dw: tuple | None = None
    codigo = 0
    try:
        arquivos = listar_arquivos(args.arquivo)
        log.info("Pipeline: %d arquivo(s): %s", len(arquivos), ", ".join(arquivos))

        log.info("Etapa 1/3: carga no Oracle (PKG_CARGA_PNAD.usp_carregar)")
        etapa_oracle(arquivos, oracle)

        log.info("Etapa 2/3: ponte Oracle -> SQL Server")
        etapa_ponte([(r.ano, r.mes) for r in oracle], args.lote, pontes)

        log.info("Etapa 3/3: DW (etl.usp_carregar_dw)")
        dw = etapa_dw()
    except (ErroPipeline, ErroConfiguracao, ponte.ErroPonte, oracledb.Error, pyodbc.Error) as exc:
        log.error("Pipeline interrompido: %s", exc)
        codigo = 1

    imprimir_resumo(oracle, pontes, dw, inicio)
    return codigo


if __name__ == "__main__":
    sys.exit(main())
