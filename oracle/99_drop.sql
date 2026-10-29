-- =====================================================================
-- Arquivo  : oracle/99_drop.sql
-- Objetivo : remover os objetos do projeto no Oracle, para recriar o
--            ambiente do zero (00_setup_sys -> 01 -> 02)
-- Etapa    : E10 - Documentacao (script de apoio)
-- Executar : parte 1 como STAGING no XEPDB1; parte 2 (opcional, comentada)
--            como SYSTEM no XEPDB1
-- Depende  : -
-- Obs      : DESTRUTIVO: apaga a staging, o LOG_CARGA, a tabela de erros
--            e o package; nao faz parte do pipeline
--          : pode ser executado de novo (objeto inexistente e ignorado)
--          : arquivos BADFILE/LOGFILE da pasta de log nao sao apagados
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

-- ---------------------------------------------------------------------
-- Parte 1: objetos do schema STAGING
-- ---------------------------------------------------------------------
DECLARE
  -- remove o objeto se existir; PURGE evita a lixeira nas tabelas comuns
  PROCEDURE remover(p_tipo IN VARCHAR2, p_nome IN VARCHAR2, p_purge IN BOOLEAN DEFAULT FALSE) IS
    v_qtd PLS_INTEGER;
  BEGIN
    SELECT COUNT(*)
      INTO v_qtd
      FROM user_objects
     WHERE object_name = p_nome
       AND object_type = p_tipo;

    IF v_qtd = 0 THEN
      DBMS_OUTPUT.PUT_LINE(p_tipo || ' ' || p_nome || ' nao existe');
    ELSE
      EXECUTE IMMEDIATE 'DROP ' || p_tipo || ' ' || p_nome
                        || CASE WHEN p_purge THEN ' PURGE' END;
      DBMS_OUTPUT.PUT_LINE(p_tipo || ' ' || p_nome || ' removido');
    END IF;
  END remover;
BEGIN
  remover('PACKAGE', 'PKG_CARGA_PNAD');                 -- spec e body
  remover('TABLE',   'PNAD_COVID_EXT');                 -- tabela externa
  remover('TABLE',   'ERR$_PNAD_COVID_PESSOA', TRUE);
  remover('TABLE',   'PNAD_COVID_PESSOA',      TRUE);   -- leva o indice
  remover('TABLE',   'LOG_CARGA',              TRUE);   -- leva a sequence da IDENTITY
END;
/

-- conferencia: objetos restantes no schema (esperado: nenhum)
SELECT object_type, object_name
  FROM user_objects
 ORDER BY object_type, object_name;

-- ---------------------------------------------------------------------
-- Parte 2 (opcional): usuario e DIRECTORYs, como SYSTEM no XEPDB1
-- ---------------------------------------------------------------------
-- DROP USER staging CASCADE;
-- DROP DIRECTORY dir_pnad_dados;
-- DROP DIRECTORY dir_pnad_log;

WHENEVER SQLERROR CONTINUE
