-- =====================================================================
-- Arquivo  : oracle/00_setup_sys.sql
-- Objetivo : preparar o PDB XEPDB1 para o projeto: usuario STAGING,
--            privilegios diretos e DIRECTORYs dos CSVs e dos logs;
--            testar leitura do CSV e escrita na pasta de log
-- Etapa    : E0 - Ambiente
-- Executar : como SYSTEM conectado ao XEPDB1 (localhost:1521/XEPDB1)
-- Depende  : container oracle-xe com /opt/oracle/pnad/dados (somente
--            leitura) e /opt/oracle/pnad/log (dono oracle)
-- Obs      : pode ser executado de novo; se STAGING ja existir, o
--            usuario e mantido (senha e objetos nao sao alterados)
--          : privilegios de sistema concedidos direto ao usuario (nao
--            via role), exigencia do DDL dinamico no package (secao 5.1)
--          : UTL_FILE vem do grant a PUBLIC (SYSTEM nao pode repassar
--            privilegio em objeto do SYS); o script so confere
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET VERIFY OFF
SET LINESIZE 200
SET PAGESIZE 100
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

ACCEPT senha_staging CHAR PROMPT 'Senha do usuario STAGING (usada so se ele ainda nao existir): ' HIDE

-- ---------------------------------------------------------------------
-- 1. Confere se a sessao esta no PDB do projeto
-- ---------------------------------------------------------------------
DECLARE
  v_con VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CON_NAME');
BEGIN
  IF v_con <> 'XEPDB1' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Conecte no XEPDB1. Sessao atual em: ' || v_con);
  END IF;
  DBMS_OUTPUT.PUT_LINE('PDB conferido: ' || v_con);
END;
/

-- ---------------------------------------------------------------------
-- 2. Usuario STAGING (cria so se nao existir)
-- ---------------------------------------------------------------------
DECLARE
  v_qtd PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_qtd FROM dba_users WHERE username = 'STAGING';

  IF v_qtd = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER staging IDENTIFIED BY "&senha_staging" '
                   || 'DEFAULT TABLESPACE users TEMPORARY TABLESPACE temp '
                   || 'QUOTA UNLIMITED ON users';
    DBMS_OUTPUT.PUT_LINE('Usuario STAGING criado');
  ELSE
    EXECUTE IMMEDIATE 'ALTER USER staging QUOTA UNLIMITED ON users';
    DBMS_OUTPUT.PUT_LINE('Usuario STAGING ja existia: mantido, quota em USERS ajustada');
  END IF;
END;
/

-- ---------------------------------------------------------------------
-- 3. Privilegios de sistema (diretos, nao via role) e UTL_FILE
-- ---------------------------------------------------------------------
GRANT CREATE SESSION   TO staging;
GRANT CREATE TABLE     TO staging;   -- tabelas e DDL dinamico da tabela externa
GRANT CREATE SEQUENCE  TO staging;   -- apoio a colunas IDENTITY
GRANT CREATE PROCEDURE TO staging;   -- package PKG_CARGA_PNAD

-- UTL_FILE: o package pode usar para ler o cabecalho do CSV.
-- Grant a PUBLIC vale dentro de package (nao e role); so conferimos.
DECLARE
  v_qtd PLS_INTEGER;
BEGIN
  SELECT COUNT(*)
    INTO v_qtd
    FROM dba_tab_privs
   WHERE owner      = 'SYS'
     AND table_name = 'UTL_FILE'
     AND privilege  = 'EXECUTE'
     AND grantee   IN ('PUBLIC', 'STAGING');

  IF v_qtd = 0 THEN
    RAISE_APPLICATION_ERROR(-20003,
      'EXECUTE em SYS.UTL_FILE ausente para PUBLIC e STAGING. Como SYS no XEPDB1: '
      || 'GRANT EXECUTE ON SYS.UTL_FILE TO staging;');
  END IF;
  DBMS_OUTPUT.PUT_LINE('UTL_FILE disponivel para STAGING (grant existente)');
END;
/

-- ---------------------------------------------------------------------
-- 4. DIRECTORYs (caminhos dentro do container)
-- ---------------------------------------------------------------------
CREATE OR REPLACE DIRECTORY dir_pnad_dados AS '/opt/oracle/pnad/dados';
CREATE OR REPLACE DIRECTORY dir_pnad_log   AS '/opt/oracle/pnad/log';

GRANT READ        ON DIRECTORY dir_pnad_dados TO staging;
GRANT READ, WRITE ON DIRECTORY dir_pnad_log   TO staging;

-- ---------------------------------------------------------------------
-- 5. Teste de leitura: cabecalho do arquivo de maio
-- ---------------------------------------------------------------------
DECLARE
  v_arq   UTL_FILE.FILE_TYPE;
  v_linha VARCHAR2(32767);
BEGIN
  v_arq := UTL_FILE.FOPEN('DIR_PNAD_DADOS', 'PNAD_COVID_052020.csv', 'r', 32767);
  UTL_FILE.GET_LINE(v_arq, v_linha);
  UTL_FILE.FCLOSE(v_arq);

  DBMS_OUTPUT.PUT_LINE('Leitura OK - inicio do cabecalho: ' || SUBSTR(v_linha, 1, 60));
  DBMS_OUTPUT.PUT_LINE('Colunas no cabecalho: ' || (REGEXP_COUNT(v_linha, ',') + 1));
  DBMS_OUTPUT.PUT_LINE('Linha termina com CHR(13) (CRLF): '
                       || CASE WHEN SUBSTR(v_linha, -1) = CHR(13) THEN 'SIM' ELSE 'NAO' END);
EXCEPTION
  WHEN OTHERS THEN
    IF UTL_FILE.IS_OPEN(v_arq) THEN
      UTL_FILE.FCLOSE(v_arq);
    END IF;
    RAISE_APPLICATION_ERROR(-20999, 'Falha ao ler DIR_PNAD_DADOS: ' || SQLERRM);
END;
/

-- ---------------------------------------------------------------------
-- 6. Teste de escrita: grava, confere e remove um arquivo no log
-- ---------------------------------------------------------------------
DECLARE
  c_nome    CONSTANT VARCHAR2(30) := 'teste_escrita_e0.txt';
  v_arq     UTL_FILE.FILE_TYPE;
  v_existe  BOOLEAN;
  v_tamanho NUMBER;
  v_bloco   BINARY_INTEGER;
BEGIN
  v_arq := UTL_FILE.FOPEN('DIR_PNAD_LOG', c_nome, 'w');
  UTL_FILE.PUT_LINE(v_arq, 'teste E0 ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  UTL_FILE.FCLOSE(v_arq);

  UTL_FILE.FGETATTR('DIR_PNAD_LOG', c_nome, v_existe, v_tamanho, v_bloco);
  IF NOT v_existe THEN
    RAISE_APPLICATION_ERROR(-20002, 'Arquivo de teste nao encontrado apos a escrita');
  END IF;

  UTL_FILE.FREMOVE('DIR_PNAD_LOG', c_nome);
  DBMS_OUTPUT.PUT_LINE('Escrita OK em DIR_PNAD_LOG (' || v_tamanho || ' bytes; arquivo removido)');
EXCEPTION
  WHEN OTHERS THEN
    IF UTL_FILE.IS_OPEN(v_arq) THEN
      UTL_FILE.FCLOSE(v_arq);
    END IF;
    RAISE_APPLICATION_ERROR(-20999, 'Falha ao gravar em DIR_PNAD_LOG: ' || SQLERRM);
END;
/

-- ---------------------------------------------------------------------
-- 7. Conferencia no dicionario de dados e versao
-- ---------------------------------------------------------------------
COLUMN username           FORMAT A10
COLUMN account_status     FORMAT A15
COLUMN default_tablespace FORMAT A12
COLUMN privilege          FORMAT A20
COLUMN grantee            FORMAT A10
COLUMN objeto             FORMAT A16
COLUMN directory_name     FORMAT A16
COLUMN directory_path     FORMAT A30
COLUMN object_type        FORMAT A20
COLUMN banner_full        FORMAT A90

SELECT username, account_status, default_tablespace
  FROM dba_users
 WHERE username = 'STAGING';

SELECT privilege
  FROM dba_sys_privs
 WHERE grantee = 'STAGING'
 ORDER BY privilege;

-- privilegios de objeto do STAGING e o UTL_FILE herdado de PUBLIC
SELECT grantee, table_name AS objeto, privilege
  FROM dba_tab_privs
 WHERE grantee = 'STAGING'
    OR (grantee = 'PUBLIC' AND owner = 'SYS' AND table_name = 'UTL_FILE')
 ORDER BY grantee, table_name, privilege;

SELECT directory_name, directory_path
  FROM dba_directories
 WHERE directory_name LIKE 'DIR_PNAD%'
 ORDER BY directory_name;

-- objetos ja existentes no schema (esperado: nenhum)
SELECT object_type, COUNT(*) AS qtd
  FROM dba_objects
 WHERE owner = 'STAGING'
 GROUP BY object_type
 ORDER BY object_type;

SELECT banner_full FROM v$version;

WHENEVER SQLERROR CONTINUE

