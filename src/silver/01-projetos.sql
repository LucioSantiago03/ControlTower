-- silver.projetos: o cadastro do PMO, limpo e tipado.
-- É o de-para da integração: ferramenta + codigo_ferramenta dizem onde está o cronograma de cada projeto.
CREATE OR REFRESH MATERIALIZED VIEW projetos (
  -- sujeira 1: 24 dos 60 projetos vêm com data em dd/MM/yyyy
  CONSTRAINT data_inicio_valida EXPECT (data_inicio IS NOT NULL) ON VIOLATION FAIL UPDATE,
  -- sujeira 2: a ferramenta vem escrita de 8 jeitos e tem que cair em 3
  CONSTRAINT ferramenta_conhecida EXPECT (ferramenta IN ('excel', 'clickup', 'msproject')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Cadastro dos 60 projetos da Vértice (PMO): cliente, segmento, tipo, valor do contrato, orçamento de custo, datas baseline, status, gerente e a ferramenta onde o cronograma é controlado (excel, clickup ou msproject) com o código do projeto nessa ferramenta.'
AS SELECT
  projeto_id,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,

  -- 'Excel', 'excel', 'Planilha', 'ClickUp', 'Clickup', 'MS Project', 'msproject', 'Project'
  CASE
    WHEN lower(ferramenta) LIKE '%excel%' OR lower(ferramenta) LIKE '%planilha%' THEN 'excel'
    WHEN lower(ferramenta) LIKE '%click%'                                        THEN 'clickup'
    WHEN lower(ferramenta) LIKE '%project%'                                      THEN 'msproject'
  END AS ferramenta,
  ferramenta AS ferramenta_como_veio,

  -- sujeira 3: dois projetos vêm com o código vazio (a silver.tarefas resolve de outro jeito)
  nullif(trim(codigo_ferramenta), '') AS codigo_ferramenta,

  CAST(valor_contrato  AS DECIMAL(14, 2)) AS valor_contrato,
  CAST(orcamento_custo AS DECIMAL(14, 2)) AS orcamento_custo,

  coalesce(try_to_date(data_inicio, 'yyyy-MM-dd'),       try_to_date(data_inicio, 'dd/MM/yyyy'))       AS data_inicio,
  coalesce(try_to_date(data_fim_baseline, 'yyyy-MM-dd'), try_to_date(data_fim_baseline, 'dd/MM/yyyy')) AS data_fim_baseline,

  status,
  gerente_projeto
FROM lakehouse_vertice.bronze.projetos;
