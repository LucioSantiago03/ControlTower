-- silver.tarefas: AS TRÊS FERRAMENTAS VIRAM UMA.
-- Cada ferramenta ganha uma visão temporária com as MESMAS 13 colunas, na mesma ordem e com os mesmos tipos:
--   projeto_id, ferramenta, id_na_ferramenta, fase, tarefa, responsavel,
--   inicio_baseline, fim_baseline, inicio_real, fim_real, pct_como_veio, horas, status_na_ferramenta
-- No fim, um UNION ALL junta as três numa tabela só.


-- 1. Excel: 20 planilhas, tudo texto
CREATE TEMPORARY VIEW tarefas_excel AS
SELECT
  -- de-para pelo nome do arquivo. Se não casar (código vazio, ou o arquivo chegou sem acento),
  -- o PRJ-xxx está no próprio nome do arquivo (sujeira 3)
  coalesce(p.projeto_id, regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0)) AS projeto_id,
  'excel'                     AS ferramenta,
  CAST(e.id AS STRING)        AS id_na_ferramenta,
  e.fase,
  e.tarefa,
  e.responsavel,

  -- sujeira 4: data em texto (dd/MM/yyyy) ou número de série do Excel (dias desde 30/12/1899)
  CASE WHEN contains(e.inicio_previsto, '/') THEN to_date(e.inicio_previsto, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(CAST(nullif(trim(e.inicio_previsto), '') AS DOUBLE) AS INT)) END  AS inicio_baseline,
  CASE WHEN contains(e.termino_previsto, '/') THEN to_date(e.termino_previsto, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(CAST(nullif(trim(e.termino_previsto), '') AS DOUBLE) AS INT)) END AS fim_baseline,
  CASE WHEN contains(e.inicio_real, '/') THEN to_date(e.inicio_real, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(CAST(nullif(trim(e.inicio_real), '') AS DOUBLE) AS INT)) END      AS inicio_real,
  CASE WHEN contains(e.termino_real, '/') THEN to_date(e.termino_real, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(CAST(nullif(trim(e.termino_real), '') AS DOUBLE) AS INT)) END     AS fim_real,

  -- sujeira 5: '45%' ou '10,5%' (tira o % e troca a vírgula) ou 0.45 (fração: × 100)
  CASE WHEN contains(e.pct_concluido, '%')
       THEN CAST(replace(replace(e.pct_concluido, '%', ''), ',', '.') AS DOUBLE)
       ELSE CAST(replace(e.pct_concluido, ',', '.') AS DOUBLE) * 100
  END AS pct_como_veio,

  -- sujeira 7: horas em '40h'
  CAST(replace(e.horas_previstas, 'h', '') AS DOUBLE) AS horas,

  CAST(NULL AS STRING) AS status_na_ferramenta     -- a planilha não tem status
FROM lakehouse_vertice.bronze.excel_tarefas e
LEFT JOIN projetos p
  ON p.ferramenta = 'excel' AND p.codigo_ferramenta = e.arquivo
-- sujeira 6: a última linha de cada planilha é o TOTAL (somaria as horas duas vezes)
WHERE coalesce(e.tarefa, '') <> 'TOTAL';


-- 2. ClickUp: 25 listas, datas em milissegundos e % / baseline dentro de custom_fields
-- (try_element_at(filter(...), 1) é o filter(...)[0] que não quebra se o campo faltar)
CREATE TEMPORARY VIEW tarefas_clickup AS
SELECT
  -- de-para pelo list_id; se o código faltar, pelo nome da lista (= nome do projeto)
  coalesce(por_codigo.projeto_id, por_nome.projeto_id) AS projeto_id,
  'clickup'                                         AS ferramenta,
  c.id                                              AS id_na_ferramenta,
  try_element_at(filter(c.custom_fields, f -> f.name = 'Fase'), 1).value AS fase,
  c.name                                            AS tarefa,
  try_element_at(c.assignees, 1).username           AS responsavel,

  -- sujeira 8: datas em milissegundos desde 1970
  to_date(timestamp_millis(CAST(try_element_at(filter(c.custom_fields, f -> f.name = 'Início baseline'), 1).value AS BIGINT))) AS inicio_baseline,
  to_date(timestamp_millis(CAST(try_element_at(filter(c.custom_fields, f -> f.name = 'Fim baseline'), 1).value AS BIGINT)))    AS fim_baseline,
  to_date(timestamp_millis(CAST(nullif(c.start_date, '') AS BIGINT))) AS inicio_real,
  to_date(timestamp_millis(CAST(nullif(c.date_done, '') AS BIGINT)))  AS fim_real,

  CAST(try_element_at(filter(c.custom_fields, f -> f.name = 'Progresso (%)'), 1).value AS DOUBLE) AS pct_como_veio,

  c.time_estimate / 3600000.0 AS horas,                  -- time_estimate vem em milissegundos

  -- sujeira 9: o status vem escrito de 12 jeitos
  CASE
    WHEN lower(trim(c.status.status)) IN ('done', 'concluído', 'closed')   THEN 'concluida'
    WHEN lower(trim(c.status.status)) IN ('to do', 'backlog', 'a fazer')   THEN 'a_fazer'
    ELSE 'em_andamento'                            -- in progress, em andamento, doing, review
  END AS status_na_ferramenta
FROM lakehouse_vertice.bronze.clickup_tarefas c
LEFT JOIN projetos por_codigo
  ON por_codigo.ferramenta = 'clickup' AND por_codigo.codigo_ferramenta = c.list_id
LEFT JOIN projetos por_nome
  ON por_nome.ferramenta = 'clickup' AND por_nome.nome_projeto = c.list_name;


-- 3. MS Project: 15 XML, com tarefas-resumo e a fase escondida na hierarquia
-- (a janela fica num CTE e o filtro no seguinte: função de janela e filtro no mesmo SELECT confundem)
CREATE TEMPORARY VIEW tarefas_msproject AS
WITH com_fase AS (
  SELECT
    m.*,
    -- sujeira 11: a fase é a última tarefa-resumo de nível 1 que aparece antes da tarefa
    last_value(CASE WHEN m.OutlineLevel = 1 THEN m.Name END, true)
      OVER (PARTITION BY m.arquivo ORDER BY m.UID) AS fase_da_tarefa
  FROM lakehouse_vertice.bronze.msproject_tarefas m
)
SELECT
  p.projeto_id,
  'msproject'                    AS ferramenta,
  CAST(t.UID AS STRING)          AS id_na_ferramenta,
  t.fase_da_tarefa               AS fase,
  t.Name                         AS tarefa,
  CAST(NULL AS STRING)           AS responsavel,     -- o XML não traz o recurso na <Task>
  to_date(t.Baseline.Start)      AS inicio_baseline,
  to_date(t.Baseline.Finish)     AS fim_baseline,
  to_date(t.ActualStart)         AS inicio_real,
  to_date(t.ActualFinish)        AS fim_real,
  CAST(t.PercentComplete AS DOUBLE) AS pct_como_veio,
  -- sujeira 12: horas em 'PT40H0M0S'
  CAST(regexp_extract(t.Work, 'PT([0-9]+)H', 1) AS DOUBLE) AS horas,
  CAST(NULL AS STRING)           AS status_na_ferramenta
FROM com_fase t
LEFT JOIN projetos p
  ON p.ferramenta = 'msproject' AND p.codigo_ferramenta = t.arquivo
-- sujeira 10: as tarefas-resumo somam as horas das de baixo (contariam duas vezes)
WHERE t.Summary = 0;


-- 4. As três numa tabela só
CREATE OR REFRESH MATERIALIZED VIEW tarefas (
  CONSTRAINT achou_o_projeto   EXPECT (projeto_id IS NOT NULL)            ON VIOLATION FAIL UPDATE,
  CONSTRAINT pct_entre_0_e_100 EXPECT (pct_concluido BETWEEN 0 AND 100)   ON VIOLATION FAIL UPDATE,
  CONSTRAINT horas_positivas   EXPECT (horas > 0)                         ON VIOLATION FAIL UPDATE
)
COMMENT 'Todas as tarefas dos cronogramas dos 60 projetos num modelo só, vindas das três ferramentas (Excel, ClickUp e MS Project): fase, responsável, datas baseline e reais, % concluído de hoje e horas previstas. Base do SPI e do CPI da fotografia atual.'
AS
WITH todas AS (
  SELECT * FROM tarefas_excel
  UNION ALL
  SELECT * FROM tarefas_clickup
  UNION ALL
  SELECT * FROM tarefas_msproject
)
SELECT
  concat_ws('-', projeto_id, ferramenta, id_na_ferramenta) AS tarefa_id,
  projeto_id,
  ferramenta,
  id_na_ferramenta,
  fase,
  tarefa,
  responsavel,
  inicio_baseline,
  fim_baseline,
  inicio_real,
  fim_real,
  -- 11 tarefas do Excel vêm com mais de 100%: corta em 100 e marca
  least(pct_como_veio, 100)   AS pct_concluido,
  pct_como_veio,
  pct_como_veio > 100         AS pct_veio_acima_de_100,
  horas,
  status_na_ferramenta
FROM todas;
