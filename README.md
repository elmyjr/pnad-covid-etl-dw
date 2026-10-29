# ETL e Data Warehouse — PNAD COVID-19 (IBGE)

Atividade prática da disciplina **MS SQL Server Operação** — MBA em Engenharia de Dados, PUC Minas.

> **Status desta entrega (29/10/2026):** pipeline completo implementado, executado e validado. Os 7 arquivos (2.650.459 linhas) foram carregados no Oracle, copiados para o SQL Server e transformados no Data Warehouse (dimensões com 7 / 53 / 2.131 linhas; fato com 201.564 linhas), com log em todas as etapas e reconciliação OK em todos os meses (seção 9.3).

---

## 1. Objetivo

Construir, executar e documentar um pipeline ETL completo sobre os microdados da PNAD COVID-19 (IBGE, 7 arquivos CSV de maio a novembro de 2020):

1. os CSVs são lidos e validados pelo **Oracle XE 21c** e carregados numa staging, com log de execução;
2. um script **Python** copia a staging do Oracle para o **SQL Server**;
3. procedures **T-SQL** transformam e normalizam os dados e carregam um **Data Warehouse dimensional**, também com log.

## 2. Arquitetura

```
CSV IBGE (7 arquivos, mai–nov/2020)
   │  Oracle lê o arquivo (tabela externa) e valida o cabeçalho
   ▼
ORACLE XE 21c ── STAGING.PNAD_COVID_PESSOA  ──► Log Oracle (STAGING.LOG_CARGA)
   │  Python lê a staging e copia, mês a mês, sem transformar
   ▼
SQL SERVER ── staging.pnad_covid_pessoa (espelho)  ──► Log SQL Server (etl.log_execucao)
   │  Procedures T-SQL: transformação e normalização (functions)
   ▼
SQL SERVER ── dw.dim_tempo / dw.dim_municipio / dw.dim_pessoa / dw.fato_pnad_covid ──► etl.log_execucao
```

O `python\pipeline.py` orquestra as três etapas, nesta ordem.

| Componente | Papel |
|---|---|
| Oracle XE 21c | Lê o CSV por tabela externa, valida o cabeçalho, grava na staging oficial e registra o log. Contém o package exigido pelo enunciado (`PKG_CARGA_PNAD`). |
| Python | Faz apenas a ponte Oracle → SQL Server e orquestra o pipeline. Não lê CSV e não transforma dados. |
| SQL Server | Guarda o espelho da staging e executa as functions, as procedures do DW e o log. |

Arquivos da entrega:

```
covid_ibge\
├── oracle\
│   ├── 00_setup_sys.sql          usuário STAGING, privilégios e DIRECTORYs (SYSTEM)
│   ├── 01_ddl_staging.sql        PNAD_COVID_PESSOA, LOG_CARGA e ERR$_PNAD_COVID_PESSOA
│   ├── 02_pkg_carga_pnad.sql     package PKG_CARGA_PNAD (usp_carregar)
│   ├── 03_testes_carga.sql       testes: sucesso parcial, erro e recarga
│   └── 99_drop.sql               desmontagem (destrutivo)
├── sqlserver\
│   ├── 00_setup_banco.sql        banco db_pnad_covid e schemas
│   ├── 01_ddl_staging_log.sql    espelho, etl.log_execucao e etl.usp_registrar_log
│   ├── 02_ddl_dw.sql             dimensões e fato (PK, FK, UNIQUE, CHECK)
│   ├── 03_functions.sql          16 functions de normalização e mapeamento
│   ├── 04_usp_dimensoes.sql      usp_carregar_dim_tempo / _municipio / _pessoa
│   ├── 05_usp_fato.sql           usp_carregar_fato
│   ├── 06_usp_carregar_dw.sql    procedure principal
│   ├── 07_validacao.sql          reconciliação, integridade e consultas analíticas
│   └── 99_drop.sql               desmontagem (destrutivo)
├── python\
│   ├── config.py                 .env, logging e conexões (executado sozinho, testa as conexões)
│   ├── ponte_oracle_sqlserver.py ponte Oracle → SQL Server
│   ├── pipeline.py               orquestração: Oracle → ponte → DW
│   └── requirements.txt
├── docs\evidencias\              prints e grades exportadas (seção 10)
├── .env.example                  modelo do .env (sem senhas)
├── .gitignore
└── README.md
```

Os CSVs (pasta `data\`), o `.env` e a venv não fazem parte da entrega.

## 3. Ambiente e configuração

| Item | Valor |
|---|---|
| Sistema | Windows, containers em Podman 6.0.2 (máquina WSL, modo rootless) |
| Pasta do projeto | `C:\dev\covid_ibge` |
| CSVs | `C:\dev\covid_ibge\data` (`PNAD_COVID_052020.csv` … `PNAD_COVID_112020.csv`) |
| Oracle | container `oracle-xe`, imagem `container-registry.oracle.com/database/express:21.3.0-xe`, **Oracle Database 21c Express Edition Release 21.0.0.0.0 – Version 21.3.0.0.0**, PDB `XEPDB1`, porta 1521 (e 5500 do EM Express) |
| Volumes do Oracle | `oracle21c-data` → `/opt/oracle/oradata` (banco) · `oracle-pnad-log` → `/opt/oracle/pnad/log` (BADFILE e LOGFILE da tabela externa) · `C:\dev\covid_ibge\data` → `/opt/oracle/pnad/dados` (somente leitura) |
| SQL Server | container `tsql`, imagem `mcr.microsoft.com/mssql/server:2022-latest`, **Microsoft SQL Server 2022 (RTM-CU27-GDR) 16.0.4305.5, Developer Edition**, collation `SQL_Latin1_General_CP1_CI_AS`, limite de memória 3 GB, porta 1434 do Windows → 1433, volume `tsql-data`; banco `db_pnad_covid` (recovery SIMPLE), schemas `staging`, `dw`, `etl` |
| Fuso dos containers | `America/Sao_Paulo` (variável `TZ`): datas dos logs no horário de Brasília |
| Python | 3.13.3 em venv (`.venv`); `oracledb` 26.1.0 (modo thin, sem Oracle Client), `pyodbc` 5.3.0 com ODBC Driver 18 for SQL Server, `python-dotenv` 1.2.4 (`python\requirements.txt`) |
| Editor | VS Code (extensões Oracle SQL Developer e SQL Server) |

### 3.1 Criação dos containers

Comandos em PowerShell (senhas no lugar de `<...>`). A pasta dos CSVs entra no Oracle **somente leitura**, e a pasta de log da tabela externa fica num volume próprio, que sobrevive à recriação do container.

```powershell
# Oracle XE 21c: banco, pasta de log e CSVs (somente leitura)
podman run -d --name oracle-xe --hostname oracle-xe `
  -p 1521:1521 -p 5500:5500 --shm-size 1g `
  -e ORACLE_PWD=<senha_oracle> -e TZ=America/Sao_Paulo `
  -v oracle21c-data:/opt/oracle/oradata `
  -v oracle-pnad-log:/opt/oracle/pnad/log `
  -v /mnt/c/dev/covid_ibge/data:/opt/oracle/pnad/dados:ro `
  container-registry.oracle.com/database/express:21.3.0-xe

# depois de "DATABASE IS READY TO USE" no log: pasta de log do usuario oracle
podman exec -u root oracle-xe chown oracle:oinstall /opt/oracle/pnad/log

# SQL Server 2022 Developer
podman run -d --name tsql --hostname tsql -p 1434:1433 `
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD=<senha_sa> `
  -e MSSQL_MEMORY_LIMIT_MB=3072 -e TZ=America/Sao_Paulo `
  -v tsql-data:/var/opt/mssql `
  mcr.microsoft.com/mssql/server:2022-latest
```

- `/mnt/c/dev/covid_ibge/data` é como a máquina Podman (WSL) enxerga `C:\dev\covid_ibge\data`.
- A primeira subida do Oracle cria o banco (10 a 20 minutos).
- Depois de reiniciar o Windows: `podman machine start; podman start oracle-xe tsql`.

### 3.2 Objetos de ambiente no Oracle (`oracle\00_setup_sys.sql`, como SYSTEM no XEPDB1)

- Usuário `STAGING` com privilégios **concedidos diretamente** (não via role), exigência do DDL dinâmico dentro do package: `CREATE SESSION`, `CREATE TABLE`, `CREATE SEQUENCE`, `CREATE PROCEDURE`.
- DIRECTORYs: `DIR_PNAD_DADOS` → `/opt/oracle/pnad/dados` (READ) e `DIR_PNAD_LOG` → `/opt/oracle/pnad/log` (READ, WRITE).
- `UTL_FILE`: disponível pelo grant padrão a `PUBLIC`, que vale dentro de package.
- O script testa, de dentro do banco, a leitura do cabeçalho de maio (114 colunas, linha terminada em CRLF) e a escrita na pasta de log.

### 3.3 SQL Server (`sqlserver\00_setup_banco.sql`, como sa)

Cria o banco `db_pnad_covid` com recovery model SIMPLE (cargas grandes e repetíveis) e os schemas `staging`, `dw` e `etl`. Pode ser executado de novo.

### 3.4 Python, credenciais e teste das conexões

O Python roda numa venv na raiz do projeto, com as versões fixadas em `python\requirements.txt`:

```powershell
py -3.13 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r python\requirements.txt
```

As credenciais ficam só no arquivo `.env`, que não é versionado (`.gitignore`). O modelo `.env.example` vai versionado, sem senhas:

| Variável | Uso |
|---|---|
| `ORACLE_HOST`, `ORACLE_PORT`, `ORACLE_SERVICE` | Oracle XE (`localhost`, 1521, `XEPDB1`) |
| `ORACLE_USER`, `ORACLE_PASSWORD` | usuário `STAGING` |
| `SQLSERVER_HOST`, `SQLSERVER_PORT`, `SQLSERVER_DATABASE` | SQL Server (`localhost`, 1434, `db_pnad_covid`) |
| `SQLSERVER_USER`, `SQLSERVER_PASSWORD` | login `sa` (D21) |
| `SQLSERVER_DRIVER` | `ODBC Driver 18 for SQL Server` |
| `SQLSERVER_TRUST_CERT` | `yes`: o ODBC 18 criptografa a conexão por padrão e o certificado do container é autoassinado |

Se o encaminhamento de portas do WSL para o `localhost` do Windows não funcionar, o host passa a ser o IP da máquina Podman (`wsl -d podman-machine-default hostname -I`), que muda a cada reinício.

`python\config.py` lê o `.env`, configura o logging e abre as duas conexões; a ponte e o pipeline importam dele. Executado sozinho, testa os dois bancos (PDB, usuário, staging por mês, versão, criptografia TLS e schemas do projeto) e termina com código 1 se algum falhar:

```powershell
python python\config.py
```

## 4. Fonte de dados

- **Arquivos:** 7 CSVs da PNAD COVID-19, de maio a novembro de 2020, separados por vírgula, sem aspas, com cabeçalho e fim de linha **CRLF**. Maio tem 114 colunas e 349.306 linhas de dados.
- **Layout variável:** as colunas mudam de quantidade e de posição entre os meses (114 em maio e junho, 145 de julho a outubro e 148 em novembro). Por isso a carga localiza cada coluna **pelo nome no cabeçalho**, e não pela posição.
- **Campo vazio** significa "Não aplicável": a pergunta não foi feita àquela pessoa.
- **Códigos com zero à esquerda** (`V1013 = 05`, `A002 = 035`, `C01011 = 04`): as colunas são lidas como texto e convertidas depois.

| Arquivo | Colunas | Linhas de dados |
|---|---|---|
| PNAD_COVID_052020.csv | 114 | 349.306 |
| PNAD_COVID_062020.csv | 114 | 381.270 |
| PNAD_COVID_072020.csv | 145 | 384.166 |
| PNAD_COVID_082020.csv | 145 | 386.520 |
| PNAD_COVID_092020.csv | 145 | 387.298 |
| PNAD_COVID_102020.csv | 145 | 380.461 |
| PNAD_COVID_112020.csv | 148 | 381.438 |
| **Total** | | **2.650.459** |

Em todos os arquivos: sem aspas, fim de linha CRLF, último campo `F006` e as 23 colunas usadas presentes.

Colunas usadas (23) e destino na staging:

| CSV | Staging | CSV | Staging |
|---|---|---|---|
| Ano | NU_ANO | B0011 | SINTOMA_FEBRE |
| V1013 | NU_MES | B0012 | SINTOMA_TOSSE |
| UF | UF | B0013 | SINTOMA_DOR_GARGANTA |
| CAPITAL | CO_MUNICIPIO | B0014 | SINTOMA_DIFICULDADE_RESPIRAR |
| A004 | COR_RACA | B0015 | SINTOMA_DOR_CABECA |
| A003 | SEXO | B0016 | SINTOMA_DOR_PEITO |
| A002 | IDADE | B0017 | SINTOMA_NAUSEA |
| A005 | ESCOLARIDADE | B0018 | SINTOMA_NARIZ |
| C01011 | FAIXA_RENDIMENTO | B0019 | SINTOMA_FADIGA |
| B0042 | ATENDIMENTO_SUS | B00110 | SINTOMA_DOR_OLHOS |
| B005 | INTERNADO | B00111 | SINTOMA_PERDA_CHEIRO_SABOR |
| | | B00112 | SINTOMA_DOR_MUSCULAR |

`DT_CARGA` recebe a data e hora da carga.

## 5. Modelo de dados

### 5.1 Staging Oracle (schema STAGING)

**`PNAD_COVID_PESSOA`:** as 24 colunas do enunciado. `INT` vira `INTEGER` e `DATETIME` vira `DATE`. Valores vazios do CSV ficam NULL. Há um índice em `(NU_ANO, NU_MES)`, usado na substituição do mês e na leitura pela ponte.

> **Extensão ao enunciado:** `NU_ANO`, `NU_MES` e `DT_CARGA` são `NOT NULL`. Uma linha sem mês nunca seria substituída numa recarga e acabaria duplicada; com a restrição, ela vai para a tabela de erros.

**`LOG_CARGA`:**

| Coluna | Tipo |
|---|---|
| id_log | NUMBER, IDENTITY, PK |
| dt_inicio, dt_fim | DATE |
| no_arquivo | VARCHAR2(100) |
| qt_linhas_lidas | NUMBER |
| qt_linhas_gravadas | NUMBER |
| qt_linhas_rejeitadas | NUMBER |
| st_execucao | VARCHAR2(20), CHECK em ('SUCESSO', 'SUCESSO PARCIAL', 'ERRO') |
| ds_observacao | VARCHAR2(4000) |

**Tabelas de apoio:**

| Tabela | Uso |
|---|---|
| `ERR$_PNAD_COVID_PESSOA` | Tabela de erros do DML error logging (`LOG ERRORS`). Guarda as linhas que falharam na conversão para INTEGER, com a mensagem de erro e uma *tag* que identifica a carga. |
| `PNAD_COVID_EXT` | Tabela externa (ORACLE_LOADER), recriada a cada carga a partir do cabeçalho do arquivo, com todas as colunas como texto. |

### 5.2 SQL Server (`db_pnad_covid`)

Scripts `sqlserver\01_ddl_staging_log.sql` e `sqlserver\02_ddl_dw.sql`, que podem ser executados de novo sem apagar dados.

**`staging.pnad_covid_pessoa` (espelho):** as 24 colunas do enunciado, com os tipos originais (`INT` e `DATETIME`). Recebe a cópia da staging Oracle feita pelo Python, sem transformação. Tem índice clusterizado em `(NU_ANO, NU_MES)`, porque a ponte apaga e regrava um mês inteiro (D25).

**`etl.log_execucao`:** log das procedures do DW e da ponte, gravado pela procedure `etl.usp_registrar_log` (D26). Ela é chamada sempre fora de transação: depois do COMMIT ou, no CATCH, depois do ROLLBACK, para o ERRO ficar registrado.

| Coluna | Tipo |
|---|---|
| id_log | INT, IDENTITY, PK |
| dt_inicio, dt_fim | DATETIME2(0) |
| no_processo | VARCHAR(60) — ex.: `usp_carregar_dim_pessoa`, `ponte_oracle_sqlserver` |
| ds_referencia | VARCHAR(100) — ex.: `2020-05` |
| qt_linhas_lidas, qt_linhas_gravadas | INT |
| st_execucao | VARCHAR(20), CHECK em ('SUCESSO', 'SUCESSO PARCIAL', 'ERRO') |
| ds_observacao | VARCHAR(4000) |

**Data Warehouse (schema `dw`).** Os campos com ★ são extensões ao enunciado (D07):

| Tabela | Colunas | Restrições |
|---|---|---|
| `dw.dim_tempo` | sk_tempo INT IDENTITY · nu_ano INT · ★ nu_mes INT · no_mes VARCHAR(20) | PK sk_tempo · UNIQUE (nu_ano, nu_mes) · CHECK nu_mes entre 1 e 12 |
| `dw.dim_municipio` | sk_municipio INT IDENTITY · ★ co_capital INT NULL · sg_uf CHAR(2) · no_municipio VARCHAR(150) | PK sk_municipio · UNIQUE (sg_uf, no_municipio) |
| `dw.dim_pessoa` | sk_pessoa INT IDENTITY · cor_raca VARCHAR(25) · sexo CHAR(1) · faixa_etaria VARCHAR(25) · escolaridade VARCHAR(50) · faixa_rendimento VARCHAR(25) | PK sk_pessoa · UNIQUE nos 5 atributos · CHECK sexo em M/F/I |
| `dw.fato_pnad_covid` | sk_tempo · sk_municipio · sk_pessoa · ★ qtd_pessoas INT · atendimento_SUS INT · internado INT · sintoma INT | PK (sk_tempo, sk_municipio, sk_pessoa) · FK para as 3 dimensões · CHECK medidas entre 0 e qtd_pessoas |

- **Grão da fato:** mês × município × perfil de pessoa. As medidas contam entrevistados (D09): `qtd_pessoas` = linhas do espelho; `atendimento_SUS` e `internado` = linhas com código 1; `sintoma` = linhas com pelo menos um dos 12 sintomas igual a 1 (D10).
- **`dim_municipio`:** as 27 capitais e um item "Demais Municipios" por UF, para quem não mora na capital (D06). O DF só tem a capital.
- **`dim_pessoa`:** dimensão de perfil, com as combinações únicas dos 5 atributos (D08), porque a PNAD não identifica a pessoa.
- **Atributos sem NULL:** código vazio vira "Não aplicável" e código fora do dicionário vira "Não informado" (D14); na sigla da UF, `NA` e `NI` (D29).
- **CHECKs de integridade** (mês, sexo e medidas) são extensões ao enunciado (D27).

## 6. Objetos implementados

### 6.1 Package `STAGING.PKG_CARGA_PNAD` (`oracle\02_pkg_carga_pnad.sql`)

| Objeto | Tipo | O que faz |
|---|---|---|
| `usp_carregar(p_no_arquivo)` | procedure pública | Carga de um CSV na staging, com log (fluxo abaixo) |
| `fn_colunas_ausentes(p_cabecalho)` | function pública | Devolve as colunas obrigatórias ausentes no cabeçalho (NULL quando todas existem) |
| `fn_mapa` | function privada | Mapeamento staging × CSV (seção 4) |
| `fn_separar` | function privada | Separa o cabeçalho em nomes: maiúsculo, sem espaços e sem CHR(13) |
| `prc_ler_arquivo` | procedure privada | Lê o cabeçalho e conta as linhas de dados com UTL_FILE; trata arquivo inexistente e vazio |
| `prc_criar_tabela_externa` | procedure privada | Recria a tabela externa a partir do cabeçalho (DDL dinâmico) |
| `prc_registrar_log` | procedure privada | Grava o `LOG_CARGA` com `PRAGMA AUTONOMOUS_TRANSACTION`, para o ERRO ficar registrado mesmo depois do ROLLBACK |

**Fluxo do `usp_carregar`:**

1. Valida o nome do arquivo. Só aceita caracteres seguros, porque o nome entra em DDL dinâmico.
2. Lê o cabeçalho e conta as linhas de dados, sem o cabeçalho.
3. Confere se as 23 colunas obrigatórias estão presentes. Se faltar alguma, encerra com ERRO e lista as ausentes na observação.
4. Recria a tabela externa com as colunas do cabeçalho:
   - `FIELDS TERMINATED BY ','`, `MISSING FIELD VALUES ARE NULL`, `REJECT LIMIT UNLIMITED`;
   - BADFILE e LOGFILE em `DIR_PNAD_LOG`, com o nome do arquivo e a data e hora da carga.
5. Apaga da staging o(s) mês(es) presentes no arquivo.
6. Insere localizando as colunas pelo nome:
   - remove o CHR(13) e os espaços de cada valor;
   - converte de texto para INTEGER na inserção;
   - as linhas que falham vão para `ERR$_PNAD_COVID_PESSOA` (`LOG ERRORS ... REJECT LIMIT UNLIMITED`), sem derrubar a carga.
7. Define o status, faz COMMIT e grava o log. Em qualquer exceção: ROLLBACK, log de ERRO e erro devolvido ao chamador.

**Status:**

| Status | Quando |
|---|---|
| SUCESSO | gravadas = lidas e lidas > 0 |
| SUCESSO PARCIAL | 0 < gravadas < lidas. A observação informa quantas linhas foram para a `ERR$` (com a tag) e quantas para o BADFILE |
| ERRO | arquivo inexistente ou vazio, cabeçalho inválido, nenhuma linha gravada ou exceção |

**Códigos de erro:** `-20001` nome de arquivo inválido · `-20002` cabeçalho inválido · `-20003` arquivo inexistente · `-20004` arquivo vazio · `-20005` arquivo sem linhas de dados · `-20006` nenhuma linha gravada · `-20999` erro inesperado (com SQLERRM).

### 6.2 Functions (`sqlserver\03_functions.sql`, schema `etl`)

| Function | Retorno |
|---|---|
| `fn_remover_espacos(@texto)` | TRIM; tabulação e quebras de linha viram espaço; sequências de espaços viram um só |
| `fn_remover_acentos(@texto)` | `TRANSLATE` com collation binária (preserva maiúsculas: `GOIÂNIA` → `GOIANIA`) |
| `fn_title_case(@texto)` | Primeira letra de cada palavra maiúscula; conectivos de, da, do, das, dos, e em minúsculo, exceto na primeira palavra (D11) |
| `fn_normalizar_texto(@texto)` | Aplica as três, nesta ordem: espaços → acentos → Title Case |
| `fn_uf_nome(@co)` · `fn_uf_sigla(@co)` | Nome da UF (mapeamento 1) e sigla, exigida pela `dim_municipio`; sigla `NA`/`NI` para NULL/fora do domínio (D29) |
| `fn_municipio_nome(@co_capital)` | Texto do mapeamento 2 sem "Município de" e sem "(UF)"; NULL → "Demais municípios" (D06) |
| `fn_sexo` · `fn_cor_raca` · `fn_escolaridade` | Descrições dos mapeamentos 3, 4 e 5 |
| `fn_faixa_etaria(@idade)` | 0–17 Criança/Adolescente · 18–29 Jovem Adulto · 30–59 Adulto · 60–130 Idoso (faixa do dicionário IBGE) |
| `fn_faixa_rendimento(@co)` | "0 - 100" … "Mais de 100.000" (mapeamento 7) |
| `fn_atendimento_sus` · `fn_internado` · `fn_sintoma` | Sim / Não / Não foi atendido / Não sabe / Ignorado (mapeamentos 8, 9 e 10) |
| `fn_nome_mes(@nu_mes)` | Janeiro … Dezembro, sem depender de `SET LANGUAGE` (D17) |

- Regra geral (D14): código NULL → "Não aplicável"; código fora do domínio → "Não informado".
- As descrições mantêm a acentuação do enunciado (D12); só o nome do município é normalizado (D11).
- As procedures aplicam as functions sobre os **valores distintos** do espelho e fazem JOIN depois, nunca linha a linha.
- O script termina com 65 testes (valores válidos, NULL e código inválido de cada function), comparados de forma binária (distingue maiúscula e acento): 65 OK. Também lista as 27 capitais e o item "Demais Municipios" como entram na `dim_municipio`.
- Arquivo em UTF-8 com BOM, por causa dos literais acentuados (`N'...'`).

### 6.3 Ponte Oracle → SQL Server (`python\ponte_oracle_sqlserver.py`)

Copia a staging do Oracle para o espelho do SQL Server, **mês a mês, sem ler CSV e sem transformar** (D18). Para cada mês, numa transação:

1. conta as linhas do mês no Oracle (mês vazio → ERRO);
2. apaga o mês no espelho (a reexecução substitui, D16);
3. lê o Oracle em lotes de 50.000 linhas e insere no espelho com `fast_executemany`;
4. confere Oracle = linhas lidas = espelho; se não bater, ROLLBACK;
5. depois do COMMIT ou do ROLLBACK, grava o `etl.log_execucao` pela `etl.usp_registrar_log` (`no_processo = ponte_oracle_sqlserver`, `ds_referencia = AAAA-MM`).

| Uso | Efeito |
|---|---|
| `python python\ponte_oracle_sqlserver.py` | copia todos os meses presentes na staging Oracle |
| `python python\ponte_oracle_sqlserver.py --mes 2020-05` | copia só o mês informado (pode repetir `--mes`) |
| `--lote N` · `--debug` | tamanho do lote · andamento de cada lote |

Status: SUCESSO quando as três contagens batem; ERRO em qualquer falha (a cópia do mês é desfeita). Para no primeiro ERRO e termina com código 1. O `pipeline.py` usa a função `executar()`.

### 6.4 Procedures das dimensões (`sqlserver\04_usp_dimensoes.sql`, schema `etl`)

| Procedure | O que faz | Lidas / gravadas no log |
|---|---|---|
| `usp_carregar_dim_tempo` | Pares distintos de `NU_ANO`/`NU_MES` do espelho; `no_mes` via `fn_nome_mes`; insere só o par novo | meses no espelho / meses novos |
| `usp_carregar_dim_municipio` | Pares distintos de `UF`/`CO_MUNICIPIO`; `sg_uf` via `fn_uf_sigla`; `no_municipio` = `fn_normalizar_texto(fn_municipio_nome(CO_MUNICIPIO))`; capital vazia vira "Demais Municipios" da UF (D06); novo = `sg_uf` + `no_municipio` ainda inexistentes | pares UF/capital / itens novos |
| `usp_carregar_dim_pessoa` | Combinações distintas dos 5 códigos; faixa etária via `fn_faixa_etaria`; sexo M/F por CASE (outro → I, D13); cor/raça, escolaridade e faixa de rendimento pelas functions; insere só o perfil novo | perfis distintos / perfis novos |

Como as três funcionam:

- leem o espelho uma vez (`SELECT DISTINCT`) e aplicam as functions só sobre os valores distintos, em tabelas de-para temporárias; o perfil sai de um JOIN com `IS NOT DISTINCT FROM`, porque códigos vazios (NULL) também precisam casar com "Não aplicável";
- inserem com `NOT EXISTS` pela chave natural, numa transação explícita; reexecutar insere 0 linhas (D16);
- status (D28): SUCESSO quando terminam sem erro; no CATCH, ROLLBACK, log de ERRO e THROW; espelho vazio → erro 50001;
- `ds_referencia` do log = meses presentes no espelho (`2020-05` ou `2020-05 a 2020-11`).

Resultado com maio: `dim_tempo` 1 (2020, 5, Maio) · `dim_municipio` 53 (27 capitais + 26 "Demais Municipios"; o DF só tem a capital) · `dim_pessoa` 1.788 perfis; reexecuções com 0 novos.

### 6.5 Fato (`sqlserver\05_usp_fato.sql`)

`etl.usp_carregar_fato` resolve as chaves, agrega as medidas e grava a fato, substituindo os meses presentes no espelho:

1. **Mapas código → chave**, montados a partir dos valores distintos do espelho, com as mesmas functions e regras das dimensões (as functions nunca rodam linha a linha). Código NULL vira `-1` nos mapas, para os JOINs com os ~2,65 milhões de linhas serem igualdades simples (hash join); os códigos válidos são ≥ 0.
2. **Uma leitura do espelho** com `LEFT JOIN` nos três mapas e `GROUP BY (sk_tempo, sk_municipio, sk_pessoa)`: `qtd_pessoas` = linhas; `atendimento_SUS` e `internado` = linhas com código 1; `sintoma` = linhas com pelo menos um dos 12 sintomas = 1 (D10).
3. **Numa transação:** DELETE dos meses do espelho na fato → linhas sem alguma chave? erro **50002** → INSERT → `SUM(qtd_pessoas)` ≠ linhas lidas? erro **50003** → COMMIT. Qualquer erro: ROLLBACK (a fato volta ao estado anterior), log de ERRO e THROW.

Log (D28): lidas = linhas do espelho; gravadas = linhas inseridas na fato. Resultado com maio: 349.306 linhas agregadas em 28.765 linhas da fato, somas 349.306 / 1.369 / 200 / 38.166, em 1 a 2 segundos.

### 6.6 Procedure principal (`sqlserver\06_usp_carregar_dw.sql`)

`etl.usp_carregar_dw` chama as quatro cargas na ordem obrigatória: `usp_carregar_dim_tempo` → `usp_carregar_dim_municipio` → `usp_carregar_dim_pessoa` → `usp_carregar_fato`.

- **Sem transação externa:** cada etapa faz o próprio COMMIT/ROLLBACK e grava o próprio log. Uma transação por cima juntaria as quatro cargas num bloqueio longo e desfaria os logs de ERRO das etapas. Reexecutar é seguro (D16).
- Para na primeira etapa com erro e registra no log qual foi (`Falha na etapa ...`), depois do log de ERRO da própria etapa.
- Log (D28): lidas = linhas do espelho; gravadas = linhas da fato nos meses do espelho; a observação traz o tamanho das dimensões e `SUM(qtd_pessoas)`.
- Teste de ERRO feito na E7: uma linha provisória com mês 13 foi barrada pelo CHECK `ck_dim_tempo_mes` (D27); nada foi gravado e o erro ficou registrado na etapa e na procedure principal.

### 6.7 Pipeline (`python\pipeline.py`)

Orquestra o pipeline de ponta a ponta, sem ler nem transformar dados (D18):

1. **Oracle:** lista os **nomes** `PNAD_COVID_MMAAAA.csv` da pasta `data` (os `TESTE_*.csv` ficam de fora), em ordem cronológica, chama `PKG_CARGA_PNAD.usp_carregar` para cada um e lê o status no `LOG_CARGA`. ERRO interrompe o pipeline; SUCESSO PARCIAL segue com aviso.
2. **Ponte:** copia para o espelho os meses carregados (`ponte_oracle_sqlserver.executar`).
3. **DW:** executa `etl.usp_carregar_dw`, mostra as mensagens de cada etapa e lê o resultado no `etl.log_execucao`.
4. **Resumo** de todas as etapas; código de saída 1 em qualquer ERRO.

| Uso | Efeito |
|---|---|
| `python python\pipeline.py` | todos os arquivos da pasta `data` |
| `python python\pipeline.py --arquivo PNAD_COVID_062020.csv` | só o arquivo informado (pode repetir) |

Execução completa (7 arquivos): cerca de 200 s — Oracle 13 a 19 s por arquivo, ponte ~12 s por mês, DW 6 s.

## 7. Decisões e justificativas

| # | Decisão | Justificativa |
|---|---|---|
| D01 | Staging no Oracle XE 21c e DW no SQL Server | Segue o diagrama da atividade; o requisito de Packages é atendido no Oracle |
| D02 | Ponte Oracle → SQL Server em Python (oracledb + pyodbc) | O SQL Server em Linux não oferece linked server para Oracle; o PolyBase com Oracle exige montar uma imagem própria do container |
| D03 | Espelho da staging no SQL Server | As procedures do DW precisam ler a staging localmente; o Python só copia |
| D04 | O CSV é lido pelo Oracle, com as colunas localizadas pelo nome do cabeçalho | O layout muda entre os meses (114 colunas em maio; 148 no dicionário de novembro) |
| D05 | Mapeamento CSV → staging da seção 4 | Conferido no dicionário do IBGE |
| D06 | CAPITAL vazio vira o item "Demais municípios" de cada UF | Mantém todas as pessoas (76% das linhas de maio não são de capital) |
| D07 | Extensões no DW: `nu_mes`, `co_capital`, `qtd_pessoas` e os itens Não aplicável / Ignorado / Não informado | Ordenação cronológica, chave de origem e cálculo de taxas |
| D08 | `dim_pessoa` como dimensão de perfil (combinações únicas dos 5 atributos) | A PNAD não identifica a pessoa |
| D09 | Medidas contam entrevistados, sem o peso amostral V1032 | O enunciado não traz o peso; limitação documentada |
| D10 | Regras das medidas: SUS = 1, internado = 1, pelo menos um sintoma = 1 | Interpretação literal do enunciado |
| D11–D13 | Title Case com conectivos em minúsculo e município sem acento; dim_pessoa com acentuação; sexo M/F (I fora do domínio) | Padrão de nomes em português; exigências do enunciado |
| D14 | NULL vira "Não aplicável"; código fora do domínio vira "Não informado" | Evita NULL nas dimensões |
| D15 | Critérios de status (seção 6.1) | O enunciado pede sucesso, sucesso parcial e erro |
| D16 | Reexecução sem duplicar, em todas as camadas | Permite repetir qualquer etapa |
| D17 | Nome do mês por function própria | DATENAME depende do idioma da sessão |
| D18 | Python só faz ponte e orquestração; credenciais no `.env` | Mantém as transformações no banco |
| D19 | Entrega em zip com README, códigos e evidências; depois, GitHub | Formato não definido pelo professor |
| D20 | No Oracle, INT vira INTEGER e DATETIME vira DATE | Tipos equivalentes |
| D21 | Python conecta no SQL Server com o login `sa` | Ambiente local de laboratório; poupa tempo (limitação, seção 12) |
| D22 | Tabelas de apoio `ERR$_PNAD_COVID_PESSOA` e `PNAD_COVID_EXT` (recriada a cada carga) | Registro de rejeitadas sem derrubar a carga; layout variável entre os meses |
| D23 | NOT NULL em `NU_ANO`, `NU_MES` e `DT_CARGA` na staging Oracle | Evita linhas sem mês, que escapariam da substituição na recarga |
| D24 | Arquivos de teste gerados das primeiras 200 linhas do CSV de maio | Mesmo layout e CRLF do arquivo real |
| D25 | Índice clusterizado em `(NU_ANO, NU_MES)` no espelho, sem mudar colunas nem tipos | A ponte apaga e regrava um mês inteiro |
| D26 | Procedure `etl.usp_registrar_log` grava o log do SQL Server, chamada fora de transação | Um único ponto de gravação do log para procedures e ponte; o ERRO fica registrado depois do ROLLBACK |
| D27 | CHECKs no DW: mês entre 1 e 12, sexo M/F/I, medidas entre 0 e `qtd_pessoas` | Barram dado incoerente na carga |
| D28 | Status das procedures do DW: SUCESSO quando terminam sem erro, ERRO em exceção. Dimensões: lidas = combinações distintas, gravadas = linhas novas (0 numa reexecução). Fato: lidas = linhas do espelho, gravadas = linhas da fato, com conferência `SUM(qtd_pessoas)` = lidas (diferença → ERRO e ROLLBACK) | A regra da D15 compara linhas lidas e gravadas, o que não vale para dimensão reexecutada nem para a fato agregada; no DW, ou entra tudo, ou nada |
| D29 | Sigla da UF: `NA` para código NULL e `NI` para código fora do domínio | `sg_uf` é CHAR(2); segue a D14 |

**Detalhes de implementação que não são óbvios:**

- **A tabela externa é recriada antes do DELETE.** DDL faz commit implícito; se fosse criada depois, confirmaria o DELETE antes do INSERT.
- **A conversão de texto para INTEGER é implícita, feita na inserção.** É essa conversão que o `LOG ERRORS` registra. Um `TO_NUMBER` explícito no SELECT derrubaria a instrução inteira na primeira linha inválida.
- **O CHR(13) é removido em cada coluna usada.** O código funciona com CRLF e com LF, qualquer que seja a coluna que fique em último lugar no mês.

## 8. Como executar

Do zero até o DW, nesta ordem. Os scripts SQL rodam no VS Code; os comandos, no PowerShell, na raiz do projeto. Nas conexões do VS Code, o host é o mesmo do `.env` (`localhost` ou o IP da máquina Podman, seção 3.4). A conexão do SQL Server abre no banco `master`; os scripts já começam com `USE db_pnad_covid`.

### 8.1 Ambiente (uma vez)

| Passo | Arquivo / comando | Ferramenta e usuário |
|---|---|---|
| 1 | Containers no ar, com a pasta dos CSVs montada (seção 3.1) | PowerShell |
| 2 | `oracle\00_setup_sys.sql` (pede a senha do STAGING) | VS Code, SYSTEM em `localhost:1521/XEPDB1` |
| 3 | `sqlserver\00_setup_banco.sql` | VS Code, sa em `localhost,1434` |
| 4 | venv, `pip install -r python\requirements.txt` e `.env` copiado do `.env.example` (seção 3.4) | PowerShell |
| 5 | `python python\config.py` (teste das duas conexões) | PowerShell, venv ativa |

### 8.2 Objetos (uma vez; podem ser executados de novo)

| Passo | Arquivos, nesta ordem | Ferramenta e usuário |
|---|---|---|
| 1 | `oracle\01_ddl_staging.sql` → `oracle\02_pkg_carga_pnad.sql` | VS Code, STAGING em `XEPDB1` |
| 2 | `sqlserver\01_ddl_staging_log.sql` → `02_ddl_dw.sql` → `03_functions.sql` → `04_usp_dimensoes.sql` → `05_usp_fato.sql` → `06_usp_carregar_dw.sql` | VS Code, sa |

### 8.3 Carga

```powershell
python python\pipeline.py
```

Carrega no Oracle todos os `PNAD_COVID_*.csv` da pasta `data`, copia os meses para o espelho e executa `etl.usp_carregar_dw`, com resumo no final (cerca de 200 s). Cada etapa também pode ser executada sozinha:

| Etapa | Comando |
|---|---|
| Carga de um arquivo no Oracle | `EXEC pkg_carga_pnad.usp_carregar('PNAD_COVID_052020.csv');` (STAGING) |
| Ponte | `python python\ponte_oracle_sqlserver.py` (todos os meses) ou `--mes AAAA-MM` |
| DW | `EXEC etl.usp_carregar_dw;` (sa) |

Toda etapa pode ser repetida sem duplicar dados (D16).

### 8.4 Validação

| Passo | Arquivo / consulta | Ferramenta e usuário |
|---|---|---|
| 1 | `sqlserver\07_validacao.sql` | VS Code, sa |
| 2 | Consulta "arquivo = staging Oracle" (seção 9.3) | VS Code, STAGING |
| 3 | Log do Oracle: `SELECT * FROM log_carga ORDER BY id_log;` | VS Code, STAGING |

### 8.5 Testes do package (opcional)

Os testes de sucesso parcial e de erro (seção 9.1) usam `TESTE_parcial.csv` e `TESTE_cabecalho.csv` na pasta `data`, gerados a partir das primeiras 200 linhas do CSV de maio (D24): no primeiro, a idade da 2ª linha vira `X9`; no segundo, sai a coluna `C01011`. Rode `oracle\03_testes_carga.sql` como STAGING. Os testes usam dados de maio e o script termina recarregando maio. O `pipeline.py` ignora os arquivos `TESTE_*.csv`.

### 8.6 Recriar do zero

`sqlserver\99_drop.sql` (sa) e `oracle\99_drop.sql` (STAGING; a parte opcional, como SYSTEM, remove o usuário e os DIRECTORYs) apagam tudo o que os scripts criam. **São destrutivos** e não fazem parte do pipeline. Depois deles, repita as seções 8.1 a 8.3.

## 9. Validação e resultados

### 9.1 Testes do package (`oracle\03_testes_carga.sql`)

| # | Arquivo | Cenário | Lidas | Gravadas | Rejeitadas | Status |
|---|---|---|---|---|---|---|
| 1 | TESTE_parcial.csv | idade `X9` em 1 linha | 200 | 199 | 1 | SUCESSO PARCIAL — 1 linha na `ERR$` (ORA-01722), 0 no BADFILE |
| 2 | NAO_EXISTE.csv | arquivo inexistente | — | 0 | — | ERRO — ORA-20003 |
| 3 | TESTE_cabecalho.csv | sem a coluna obrigatória C01011 | 200 | 0 | 200 | ERRO — ORA-20002 "Colunas ausentes: C01011" |
| 4 | PNAD_COVID_052020.csv | carga real de maio | 349.306 | 349.306 | 0 | SUCESSO (≈ 7 s; substituiu as 199 linhas do teste 1) |
| 5 | PNAD_COVID_052020.csv | recarga de maio | 349.306 | 349.306 | 0 | SUCESSO (substituiu 349.306; staging continua com 349.306) |

Os testes da E2 foram executados antes da configuração do fuso dos containers; os horários deles nos prints estão em UTC. A partir da E3, os registros estão no horário de Brasília.

### 9.2 Conferência do conteúdo de maio contra o perfil do arquivo

| Indicador | Esperado | Staging Oracle |
|---|---|---|
| Linhas de 2020/05 | 349.306 | 349.306 ✔ |
| Homens / Mulheres | 167.712 / 181.594 | 167.712 / 181.594 ✔ |
| Linhas de capital (CAPITAL preenchido) | 82.115 | 82.115 ✔ |
| Faixa de rendimento preenchida | 132.375 | 132.375 ✔ |
| Atendimento SUS = 1 | 1.369 | 1.369 ✔ |
| Internado = 1 | 200 | 200 ✔ |
| Pelo menos um sintoma = 1 | 38.166 | 38.166 ✔ |
| Idade mínima / máxima | 0 / 111 | 0 / 111 ✔ |

Os valores batem, o que confirma a conversão dos códigos com zero à esquerda e a remoção do CHR(13).

### 9.3 Reconciliação dos 7 meses (`sqlserver\07_validacao.sql` e consulta no Oracle)

A cadeia conferida em cada mês é **arquivo = staging Oracle = espelho = `SUM(qtd_pessoas)` na fato**, e as medidas da fato são recalculadas direto no espelho. O SQL Server não enxerga o Oracle, então a conferência tem duas pontas:

- **No Oracle** (consulta abaixo, como STAGING): linhas lidas do arquivo = linhas gravadas = linhas da staging, pela última carga de cada arquivo no `LOG_CARGA`.
- **No SQL Server** (`07_validacao.sql`): linhas contadas no Oracle pela ponte na hora da cópia (`etl.log_execucao`) = espelho = `SUM(qtd_pessoas)`; medidas da fato = contagens no espelho; integridade; última execução de cada processo; consultas analíticas.

```sql
-- Oracle, como STAGING: arquivo = staging Oracle
SELECT l.no_arquivo,
       l.qt_linhas_lidas    AS arquivo,
       l.qt_linhas_gravadas AS gravadas,
       s.linhas             AS staging_oracle,
       CASE WHEN l.qt_linhas_lidas = l.qt_linhas_gravadas
             AND l.qt_linhas_gravadas = s.linhas
            THEN 'OK' ELSE 'DIVERGENTE' END AS conferencia
  FROM (SELECT no_arquivo, qt_linhas_lidas, qt_linhas_gravadas,
               ROW_NUMBER() OVER (PARTITION BY no_arquivo ORDER BY id_log DESC) AS ordem
          FROM log_carga
         WHERE st_execucao IN ('SUCESSO', 'SUCESSO PARCIAL')
           AND no_arquivo LIKE 'PNAD\_COVID\_%' ESCAPE '\') l
  JOIN (SELECT nu_ano, nu_mes, COUNT(*) AS linhas
          FROM pnad_covid_pessoa
         GROUP BY nu_ano, nu_mes) s
    ON s.nu_ano = TO_NUMBER(SUBSTR(l.no_arquivo, 14, 4))
   AND s.nu_mes = TO_NUMBER(SUBSTR(l.no_arquivo, 12, 2))
 WHERE l.ordem = 1
 ORDER BY s.nu_ano, s.nu_mes;
```

**Resultado (29/10/2026, depois do `pipeline.py`):** OK em todos os meses, nas duas pontas.

| Mês | Arquivo = staging Oracle = espelho = SUM(qtd_pessoas) | Linhas na fato | SUS = 1 | Internado = 1 | Algum sintoma |
|---|---|---|---|---|---|
| 2020-05 | 349.306 | 28.765 | 1.369 | 200 | 38.166 |
| 2020-06 | 381.270 | 29.331 | 1.169 | 227 | 28.280 |
| 2020-07 | 384.166 | 28.676 | 1.158 | 265 | 24.865 |
| 2020-08 | 386.520 | 28.692 | 1.072 | 253 | 22.133 |
| 2020-09 | 387.298 | 28.804 | 747 | 199 | 16.492 |
| 2020-10 | 380.461 | 28.634 | 808 | 182 | 13.628 |
| 2020-11 | 381.438 | 28.662 | 864 | 198 | 13.814 |
| **Total** | **2.650.459** | **201.564** | **7.187** | **1.524** | **157.378** |

- **Integridade:** 0 linhas da fato sem dimensão, 0 FKs desabilitadas ou não confiáveis, 0 medidas maiores que `qtd_pessoas`, 0 itens "Não informado" (nenhum código fora do dicionário nos 7 meses).
- **Dimensões:** `dim_tempo` 7 · `dim_municipio` 53 · `dim_pessoa` 2.131 — todas as linhas usadas pela fato.
- **Log:** a última execução de cada processo (ponte de cada mês, as três dimensões, a fato e a procedure principal) terminou com SUCESSO.
- Os valores também batem com uma contagem independente feita direto nos CSVs, fora do pipeline, com as mesmas regras de mapeamento (inclusive os 1.788 perfis de maio por atributo).

**Consultas analíticas de exemplo** (bloco 4 do `07_validacao.sql`; contam entrevistados, sem o peso amostral — D09):

| Mês | % com algum sintoma | % que buscou PS do SUS/UPA | Internados por 100 mil |
|---|---|---|---|
| Maio | 10,93 | 0,39 | 57,3 |
| Junho | 7,42 | 0,31 | 59,5 |
| Julho | 6,47 | 0,30 | 69,0 |
| Agosto | 5,73 | 0,28 | 65,5 |
| Setembro | 4,26 | 0,19 | 51,4 |
| Outubro | 3,58 | 0,21 | 47,8 |
| Novembro | 3,62 | 0,23 | 51,9 |

- Os sintomas caem de maio a outubro, com leve alta em novembro; as internações têm pico em julho.
- As capitais têm proporção de sintomas maior que os demais municípios em todos os meses (maio: 14,70% × 9,77%).
- Idosos: 156,6 internados por 100 mil entrevistados, contra 15,9 entre crianças e adolescentes.
- Maior proporção de sintomas no período: Amapá (10,17%), seguido de Paraíba e Rio Grande do Sul.

## 10. Evidências

Prints (PNG) em `docs\evidencias\`. Algumas grades de resultado foram exportadas em **CSV** em vez de print, para guardar o resultado completo num só arquivo (indicadas na coluna Arquivo).

| Etapa | Arquivo | Conteúdo |
|---|---|---|
| E0 | E0_diagnostico_ambiente_1..4.png | Diagnóstico Podman: containers, volumes, portas, Python e driver ODBC |
| E0 | E0_oracle_xe_montagem.png | oracle-xe recriado: pasta dos CSVs montada somente leitura, pasta de log e testes como usuário oracle |
| E0 | E0_oracle_setup_sys.png | `00_setup_sys.sql`: usuário, privilégios, DIRECTORYs, testes de leitura/escrita e versão do Oracle |
| E0 | E0_oracle_conexao_staging.png | Conexão como STAGING e DIRECTORYs visíveis |
| E0 | E0_sqlserver_setup_banco.png | Banco `db_pnad_covid` e schemas |
| E0 | E0_python_venv.png | Venv: versão do Python, bibliotecas e drivers ODBC |
| E0 | E0_config_conexoes.png | `config.py`: conexão com os dois bancos, staging de maio, TLS e schemas |
| E1 | E1_ddl_staging.png | Tabelas, constraints e índices da staging |
| E2 | E2_pkg_compilado.png | Package e body VALID; teste da `fn_colunas_ausentes` |
| E2 | E2_testes_carga_saida.png | Saída dos 5 testes |
| E2 | E2_log_carga.png | LOG_CARGA com SUCESSO PARCIAL, ERRO e SUCESSO |
| E2 | E2_erro_dml_e_staging.png | Linha rejeitada na ERR$, contagem da staging e perfil de maio |
| E3 | E3_ddl_staging_log.png | Espelho (24 colunas, 23 INT + 1 DATETIME), índice clusterizado, `etl.log_execucao` e `etl.usp_registrar_log` |
| E3 | E3_ddl_dw.png | Tabelas do DW, PK, UNIQUE, FKs habilitadas e confiáveis, CHECKs |
| E4 | E4_functions_testes.csv | Resultado dos 65 testes das functions (todos OK) |
| E4 | E4_functions_resumo.csv | As 27 capitais e o item "Demais" mapeados e normalizados para a `dim_municipio` |
| E5 | E5_ponte_execucao.png | Ponte: carga de maio (7 lotes, 349.306 linhas, ~12 s), reexecução substituindo o mês e ERRO para mês ausente (código de saída 1) |
| E5 | E5_ponte_espelho_log.png | Espelho com 349.306 linhas de 2020/05 e `DT_CARGA` copiada do Oracle; log da ponte (SUCESSO, SUCESSO, ERRO); perfil de maio igual ao do Oracle |
| E6 | E6_dimensoes_execucao.png | Mensagens das procedures das dimensões (reexecução com 0 novos) |
| E6 | E6_dimensoes_conferencia_1.csv | Log das dimensões: carga (1/1, 53/53, 1.788/1.788) e reexecuções (gravadas 0), todas SUCESSO |
| E6 | E6_dimensoes_conferencia_2.png | Totais (1, 53, 27 capitais, 26 demais, 1.788 perfis) e `dim_tempo` |
| E6 | E6_dimensoes_conferencia_3.csv | Os 53 itens da `dim_municipio` |
| E6 | E6_dimensoes_conferencia_4.csv | Perfis da `dim_pessoa` por atributo (iguais à verificação independente nos CSVs) |
| E7 | E7_fato_execucao_1.png | `usp_carregar_fato`: carga de maio (349.306 linhas → 28.765 linhas da fato) e reexecução substituindo o mês |
| E7 | E7_fato_execucao_2.png | Teste de ERRO 50002 (linha provisória sem `dim_tempo`): ROLLBACK, fato intacta |
| E7 | E7_fato_conferencia.png | Totais da fato (28.765 · 349.306 · 1.369 · 200 · 38.166), faixa etária, capitais × demais, integridade (0) e log |
| E7 | E7_carregar_dw_execucao_1.png | As 6 procedures do schema `etl` |
| E7 | E7_carregar_dw_execucao_2.png | `usp_carregar_dw`: as 4 etapas em ordem e o resumo (1 / 53 / 1.788; 28.765 linhas; 349.306 pessoas) |
| E7 | E7_carregar_dw_log.png | Log: execução completa com SUCESSO e teste de ERRO (mês 13 barrado pelo CHECK `ck_dim_tempo_mes`, registrado na etapa e na procedure principal) |
| E8 | E8_pipeline_execucao.png | Pipeline completo: 7 arquivos SUCESSO no Oracle, 7 meses na ponte, DW com 7 / 53 / 2.131 e 201.564 linhas na fato; resumo e código de saída 0 (200 s) |
| E8 | E8_oracle_log_carga.png | Staging Oracle com os 7 meses |
| E8 | E8_sqlserver_log_dw.png | Log da execução (ponte, dimensões, fato e procedure principal, todos SUCESSO), totais do DW e fato por mês |
| E9 | E9_oracle_arquivo_staging.png | Oracle: arquivo = gravadas = staging nos 7 meses (OK) |
| E9 | E9_validacao_reconciliacao.png | Reconciliação por mês (linhas e medidas OK), totais, integridade (0) e dimensões usadas |
| E9 | E9_validacao_analiticas.png | Consultas analíticas: evolução mensal, UFs, capitais × demais, faixa etária e faixa de rendimento |

## 11. Dificuldades encontradas

| Etapa | Problema | Causa | Solução |
|---|---|---|---|
| E0 | O container `oracle-xe` não tinha a pasta dos CSVs montada | Container criado antes do projeto | Recriado com montagem somente leitura, reaproveitando o volume `oracle21c-data`, após backup do volume |
| E0 | `GRANT EXECUTE ON SYS.UTL_FILE` como SYSTEM falhou com ORA-01031 | O SYSTEM não pode repassar privilégio em objeto do SYS (`GRANT ANY OBJECT PRIVILEGE` não cobre o schema SYS) | O script passou a conferir o grant padrão a PUBLIC, que vale dentro de package |
| E0 | As portas dos containers não respondiam por `localhost` no Windows | O encaminhamento de portas do WSL para o `localhost` do Windows não publicou as portas 1521 e 1434 da máquina Podman | Conexões pelo IP da máquina Podman (`wsl -d podman-machine-default hostname -I`), configurável no `.env` (`ORACLE_HOST`, `SQLSERVER_HOST`) e nas conexões do VS Code |
| E6/E7 | A faixa de rendimento é vazia (NULL) em cerca de 62% das linhas, e um JOIN comum entre códigos e de-para perde essas linhas | Em SQL, `NULL = NULL` não é verdadeiro | Dimensões: JOIN com `IS NOT DISTINCT FROM` (SQL Server 2022); fato: código NULL vira `-1` nos mapas, mantendo igualdade simples e hash join sobre 2,65 milhões de linhas |
| E9 | A reconciliação arquivo = staging Oracle = espelho = fato não cabe numa consulta só | O SQL Server não enxerga o Oracle (sem linked server para Oracle no Linux, D02) | Conferência em duas pontas: no Oracle (`LOG_CARGA` × staging) e no SQL Server (contagem feita pela ponte × espelho × fato), seção 9.3 |

## 12. Limitações e melhorias

- **Login `sa`:** a conexão do Python ao SQL Server usa o login `sa` (D21). Em produção, o ideal seria um login dedicado com permissão só no banco do projeto.
- **Sem peso amostral:** as medidas do DW contam entrevistados, sem o peso V1032 (D09). Não representam a população brasileira; os percentuais da seção 9.3 são da amostra. Melhoria: levar o peso para a staging e somá-lo na fato.
- **Host das conexões:** quando o encaminhamento de `localhost` do WSL não funciona, o `.env` usa o IP da máquina Podman, que muda a cada reinício. Melhoria: rede em modo usuário do Podman (`podman machine set --user-mode-networking=true`).
- **Staging duplicada:** os 2,65 milhões de linhas ficam na staging do Oracle e no espelho do SQL Server, consequência da arquitetura (o DW lê o espelho localmente, D03). Melhoria: limpar o espelho depois da carga do DW.
- **Carga por mês inteiro:** a ponte e a fato substituem meses completos; não há carga incremental por linha, o que é adequado aos arquivos mensais do IBGE.
- **Orquestração manual:** o `pipeline.py` é executado à mão. Melhoria: agendamento (Agendador de Tarefas do Windows) e alerta a partir dos logs.
- **Testes:** os testes são scripts SQL com conferência visual. Melhoria: testes automatizados (por exemplo, pytest para a ponte e tSQLt para as procedures).
