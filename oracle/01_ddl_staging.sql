-- =====================================================================
-- Arquivo  : oracle/01_ddl_staging.sql
-- Objetivo : criar a staging PNAD_COVID_PESSOA, o LOG_CARGA e a tabela
--            de erros do DML error logging (ERR$_PNAD_COVID_PESSOA)
-- Etapa    : E1 - Staging Oracle
-- Executar : como STAGING no XEPDB1
-- Depende  : oracle/00_setup_sys.sql
-- Obs      : pode ser executado de novo: cria so o que nao existe
--            (nao apaga dados)
--          : INT -> INTEGER e DATETIME -> DATE (D20)
--          : NOT NULL em NU_ANO, NU_MES e DT_CARGA (D23, extensao)
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  -- cria o objeto so se ainda nao existir
  PROCEDURE criar(p_nome IN VARCHAR2, p_ddl IN VARCHAR2) IS
    v_qtd PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO v_qtd FROM user_objects WHERE object_name = p_nome;
    IF v_qtd = 0 THEN
      EXECUTE IMMEDIATE p_ddl;
      DBMS_OUTPUT.PUT_LINE(p_nome || ' criado');
    ELSE
      DBMS_OUTPUT.PUT_LINE(p_nome || ' ja existe: mantido');
    END IF;
  END criar;
BEGIN
  -- staging (24 colunas do enunciado)
  criar('PNAD_COVID_PESSOA', q'[
    CREATE TABLE pnad_covid_pessoa (
      nu_ano                       INTEGER NOT NULL,
      nu_mes                       INTEGER NOT NULL,
      uf                           INTEGER,
      co_municipio                 INTEGER,
      cor_raca                     INTEGER,
      sexo                         INTEGER,
      idade                        INTEGER,
      escolaridade                 INTEGER,
      faixa_rendimento             INTEGER,
      atendimento_sus              INTEGER,
      internado                    INTEGER,
      sintoma_febre                INTEGER,
      sintoma_tosse                INTEGER,
      sintoma_dor_garganta         INTEGER,
      sintoma_dificuldade_respirar INTEGER,
      sintoma_dor_cabeca           INTEGER,
      sintoma_dor_peito            INTEGER,
      sintoma_nausea               INTEGER,
      sintoma_nariz                INTEGER,
      sintoma_fadiga               INTEGER,
      sintoma_dor_olhos            INTEGER,
      sintoma_perda_cheiro_sabor   INTEGER,
      sintoma_dor_muscular         INTEGER,
      dt_carga                     DATE    NOT NULL
    )]');

  -- apoio ao DELETE por mes e a leitura da ponte
  criar('IX_PNAD_PESSOA_ANO_MES', q'[
    CREATE INDEX ix_pnad_pessoa_ano_mes ON pnad_covid_pessoa (nu_ano, nu_mes)]');

  -- log de execucao da carga
  criar('LOG_CARGA', q'[
    CREATE TABLE log_carga (
      id_log               NUMBER GENERATED ALWAYS AS IDENTITY
                           CONSTRAINT pk_log_carga PRIMARY KEY,
      dt_inicio            DATE,
      dt_fim               DATE,
      no_arquivo           VARCHAR2(100),
      qt_linhas_lidas      NUMBER,
      qt_linhas_gravadas   NUMBER,
      qt_linhas_rejeitadas NUMBER,
      st_execucao          VARCHAR2(20)
                           CONSTRAINT ck_log_carga_status
                           CHECK (st_execucao IN ('SUCESSO', 'SUCESSO PARCIAL', 'ERRO')),
      ds_observacao        VARCHAR2(4000)
    )]');

  -- tabela de erros do DML error logging (mesma estrutura do DBMS_ERRLOG)
  criar('ERR$_PNAD_COVID_PESSOA', q'[
    CREATE TABLE err$_pnad_covid_pessoa (
      ora_err_number$              NUMBER,
      ora_err_mesg$                VARCHAR2(2000),
      ora_err_rowid$               UROWID(4000),
      ora_err_optyp$               VARCHAR2(2),
      ora_err_tag$                 VARCHAR2(2000),
      nu_ano                       VARCHAR2(4000),
      nu_mes                       VARCHAR2(4000),
      uf                           VARCHAR2(4000),
      co_municipio                 VARCHAR2(4000),
      cor_raca                     VARCHAR2(4000),
      sexo                         VARCHAR2(4000),
      idade                        VARCHAR2(4000),
      escolaridade                 VARCHAR2(4000),
      faixa_rendimento             VARCHAR2(4000),
      atendimento_sus              VARCHAR2(4000),
      internado                    VARCHAR2(4000),
      sintoma_febre                VARCHAR2(4000),
      sintoma_tosse                VARCHAR2(4000),
      sintoma_dor_garganta         VARCHAR2(4000),
      sintoma_dificuldade_respirar VARCHAR2(4000),
      sintoma_dor_cabeca           VARCHAR2(4000),
      sintoma_dor_peito            VARCHAR2(4000),
      sintoma_nausea               VARCHAR2(4000),
      sintoma_nariz                VARCHAR2(4000),
      sintoma_fadiga               VARCHAR2(4000),
      sintoma_dor_olhos            VARCHAR2(4000),
      sintoma_perda_cheiro_sabor   VARCHAR2(4000),
      sintoma_dor_muscular         VARCHAR2(4000),
      dt_carga                     VARCHAR2(4000)
    )]');
END;
/

-- conferencia no dicionario de dados
COLUMN table_name      FORMAT A25
COLUMN constraint_name FORMAT A25
COLUMN search_condition_vc FORMAT A60

SELECT t.table_name,
       (SELECT COUNT(*) FROM user_tab_columns c WHERE c.table_name = t.table_name) AS qtd_colunas
  FROM user_tables t
 WHERE t.table_name IN ('PNAD_COVID_PESSOA', 'LOG_CARGA', 'ERR$_PNAD_COVID_PESSOA')
 ORDER BY t.table_name;

SELECT table_name, constraint_name, constraint_type, search_condition_vc
  FROM user_constraints
 WHERE table_name IN ('PNAD_COVID_PESSOA', 'LOG_CARGA')
   AND constraint_name NOT LIKE 'SYS_C%'
    OR (table_name = 'PNAD_COVID_PESSOA' AND constraint_type = 'C')
 ORDER BY table_name, constraint_name;

SELECT index_name, table_name FROM user_indexes
 WHERE table_name IN ('PNAD_COVID_PESSOA', 'LOG_CARGA')
 ORDER BY index_name;

WHENEVER SQLERROR CONTINUE