-- Conferência da bronze: a ingestão trouxe tudo?
-- Compara a contagem de cada uma das 9 tabelas com o esperado (seed 42).
-- bronze.feriados fica de fora: ela cresce a cada execução.
-- Se alguma tabela divergir, a tarefa falha e o medalhão não roda.

-- 1. Uma linha por tabela: esperado × obtido
WITH esperado (tabela, esperado) AS (
  VALUES ('projetos', 60),
         ('status_semanal', 3911),
         ('excel_tarefas', 1663),
         ('clickup_tarefas', 2119),
         ('msproject_tarefas', 1260),
         ('colaboradores', 523),
         ('apontamentos', 30883),
         ('custos', 23640),
         ('entregas_fornecedor', 640)
),
obtido AS (
  SELECT 'projetos' AS tabela, count(*) AS obtido FROM lakehouse_vertice.bronze.projetos
  UNION ALL SELECT 'status_semanal',      count(*) FROM lakehouse_vertice.bronze.status_semanal
  UNION ALL SELECT 'excel_tarefas',       count(*) FROM lakehouse_vertice.bronze.excel_tarefas
  UNION ALL SELECT 'clickup_tarefas',     count(*) FROM lakehouse_vertice.bronze.clickup_tarefas
  UNION ALL SELECT 'msproject_tarefas',   count(*) FROM lakehouse_vertice.bronze.msproject_tarefas
  UNION ALL SELECT 'colaboradores',       count(*) FROM lakehouse_vertice.bronze.colaboradores
  UNION ALL SELECT 'apontamentos',        count(*) FROM lakehouse_vertice.bronze.apontamentos
  UNION ALL SELECT 'custos',              count(*) FROM lakehouse_vertice.bronze.custos
  UNION ALL SELECT 'entregas_fornecedor', count(*) FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT e.tabela,
       e.esperado,
       o.obtido,
       CASE WHEN e.esperado = o.obtido THEN 'ok' ELSE 'DIVERGENTE' END AS situacao
FROM esperado e
JOIN obtido o USING (tabela)
ORDER BY e.tabela;

-- 2. Se alguma divergir, para o job dizendo qual tabela e onde olhar
WITH esperado (tabela, esperado) AS (
  VALUES ('projetos', 60),
         ('status_semanal', 3911),
         ('excel_tarefas', 1663),
         ('clickup_tarefas', 2119),
         ('msproject_tarefas', 1260),
         ('colaboradores', 523),
         ('apontamentos', 30883),
         ('custos', 23640),
         ('entregas_fornecedor', 640)
),
obtido AS (
  SELECT 'projetos' AS tabela, count(*) AS obtido FROM lakehouse_vertice.bronze.projetos
  UNION ALL SELECT 'status_semanal',      count(*) FROM lakehouse_vertice.bronze.status_semanal
  UNION ALL SELECT 'excel_tarefas',       count(*) FROM lakehouse_vertice.bronze.excel_tarefas
  UNION ALL SELECT 'clickup_tarefas',     count(*) FROM lakehouse_vertice.bronze.clickup_tarefas
  UNION ALL SELECT 'msproject_tarefas',   count(*) FROM lakehouse_vertice.bronze.msproject_tarefas
  UNION ALL SELECT 'colaboradores',       count(*) FROM lakehouse_vertice.bronze.colaboradores
  UNION ALL SELECT 'apontamentos',        count(*) FROM lakehouse_vertice.bronze.apontamentos
  UNION ALL SELECT 'custos',              count(*) FROM lakehouse_vertice.bronze.custos
  UNION ALL SELECT 'entregas_fornecedor', count(*) FROM lakehouse_vertice.bronze.entregas_fornecedor
),
divergentes AS (
  SELECT concat_ws(', ', collect_list(
           concat('bronze.', e.tabela, ' (esperado ', e.esperado, ', obtido ', o.obtido, ')'))) AS lista,
         count(*) AS qtd
  FROM esperado e
  JOIN obtido o USING (tabela)
  WHERE e.esperado <> o.obtido
)
SELECT CASE
         WHEN qtd = 0 THEN 'bronze conferida: 9 tabelas ok'
         ELSE CAST(raise_error(concat(
                'Bronze divergente: ', lista,
                '. Olhe a saída da tarefa ingestao_data_lake (os arquivos chegaram ao volume bronze.raw?)'))
              AS STRING)
       END AS conferencia
FROM divergentes;
