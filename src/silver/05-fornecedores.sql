-- silver.entregas_fornecedor: o que as consultorias prometeram × o que entregaram.
-- Não tem tabela gold: o dashboard lê direto daqui.
CREATE OR REFRESH MATERIALIZED VIEW entregas_fornecedor
COMMENT 'Entregas das consultorias contratadas: data do pedido, data prometida e data de entrega (vazia = ainda em aberto), prazos em dias e atraso. em_atraso marca as entregas em aberto com data prometida antes de hoje (16/10/2026).'
AS
WITH tipado AS (
  SELECT
    entrega_id,
    projeto_id,
    -- sujeira 15: a CodeForge vem de 4 jeitos ('Code Forge Consultoria', 'CODEFORGE CONSULTORIA LTDA'...)
    CASE WHEN replace(lower(fornecedor), ' ', '') LIKE '%codeforge%'
         THEN 'CodeForge Consultoria Ltda'
         ELSE fornecedor
    END                                         AS fornecedor,
    fornecedor                                  AS fornecedor_como_veio,
    item,
    CAST(valor AS DECIMAL(14, 2))               AS valor,
    to_date(data_pedido)                        AS data_pedido,
    to_date(data_prometida)                     AS data_prometida,
    -- data de entrega vazia = ainda não entregou (não é sujeira)
    to_date(nullif(trim(data_entrega), ''))     AS data_entrega,
    CAST(prazo_contratado_dias AS INT)          AS prazo_contratado_dias,
    status
  FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT
  *,
  datediff(data_prometida, data_pedido)  AS prazo_prometido_dias,
  datediff(data_entrega,   data_pedido)  AS prazo_real_dias,        -- NULL enquanto em aberto
  datediff(data_entrega,   data_prometida) AS dias_de_atraso_na_entrega,
  data_entrega IS NULL                   AS em_aberto,
  -- o "hoje" do dataset é fixo: nunca current_date()
  data_entrega IS NULL AND data_prometida < DATE'2026-10-16' AS em_atraso
FROM tipado;
