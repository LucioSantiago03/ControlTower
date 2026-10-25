-- gold.status_estruturado: o texto livre do status semanal vira coluna.
-- A IA (ai_classify + ai_extract, versão 2.0) leva uns 5 s por texto, então ela só lê o que vale a pena:
--   regra          → status vazio ou que já diz "sem bloqueios" (não precisa de IA)
--   ia             → status COM bloqueio dos últimos 90 dias (desde 18/07/2026, ~160 textos)
--   palavra_chave  → o histórico mais antigo, por RLIKE
-- A tabela ACUMULA: o MERGE só insere os status que ainda não estão nela,
-- então a IA nunca é refeita para um texto já classificado.
-- Atenção: a sql_task corta o arquivo em todo ponto e vírgula, então nenhum texto daqui usa um.


-- 1. A tabela (nunca CREATE OR REPLACE: apagaria o que a IA já classificou)
CREATE TABLE IF NOT EXISTS lakehouse_vertice.gold.status_estruturado (
  projeto_id       STRING    COMMENT 'Código do projeto (PRJ-xxx).',
  data_status      DATE      COMMENT 'Sexta-feira do status semanal.',
  farol            STRING    COMMENT 'Farol declarado pelo gerente: verde, amarelo ou vermelho.',
  causa_bloqueio   STRING    COMMENT 'Causa do bloqueio: change_freeze, falta_sre, dependencia_fornecedor, rotatividade, mudanca_escopo, bug_retrabalho, aprovacao_cliente, sem_bloqueio, nao_reportado (status vazio) ou nao_classificado (nenhuma palavra-chave casou).',
  bloqueio         STRING    COMMENT 'O bloqueio em uma frase, extraído pela IA (só quando metodo = ia).',
  quem_destrava    STRING    COMMENT 'Quem precisa agir para destravar (área, pessoa ou fornecedor), extraído pela IA (só quando metodo = ia).',
  dias_impacto     DOUBLE    COMMENT 'Dias de impacto no cronograma declarados no status (1 semana = 7). Vazio quando o texto não informa.',
  metodo           STRING    COMMENT 'Como a linha foi classificada: regra (vazio ou sem bloqueio), ia (bloqueio nos últimos 90 dias) ou palavra_chave (histórico).',
  texto_status     STRING    COMMENT 'Texto livre original do status semanal.',
  _classificado_em TIMESTAMP COMMENT 'Quando a linha entrou na tabela (carimbo técnico da carga, não é a data do negócio).'
)
COMMENT 'Status semanal estruturado: para cada projeto e sexta, a causa do bloqueio, o bloqueio, quem destrava e os dias de impacto, lidos do texto livre do gerente por regra, por IA (últimos 90 dias, com bloqueio) ou por palavra-chave (histórico). Carga incremental: cada status é classificado uma vez só.';


-- 2. Só os status novos (LEFT ANTI JOIN), cada um pelo método mais barato que resolve
MERGE INTO lakehouse_vertice.gold.status_estruturado t
USING (
  WITH novos AS (
    SELECT
      s.projeto_id,
      s.data_status,
      s.farol,
      s.texto_status,
      s.status_vazio,
      lower(coalesce(s.texto_status, '')) AS texto,
      CASE
        WHEN s.status_vazio
          OR lower(s.texto_status) RLIKE 'bloqueios: nenhum|sem bloqueios|nada relevante' THEN 'regra'
        WHEN s.data_status >= DATE'2026-07-18'                                         THEN 'ia'
        ELSE 'palavra_chave'
      END AS metodo
    FROM lakehouse_vertice.silver.status_semanal s
    LEFT ANTI JOIN lakehouse_vertice.gold.status_estruturado ja
      ON ja.projeto_id = s.projeto_id AND ja.data_status = s.data_status
  ),

  -- a IA roda SÓ nas linhas com metodo = 'ia' (uma chamada de cada função por texto)
  chamadas_ia AS (
    SELECT
      *,
      ai_classify(
        texto_status,
        '["change_freeze","falta_sre","dependencia_fornecedor","rotatividade","mudanca_escopo","bug_retrabalho","aprovacao_cliente","sem_bloqueio"]',
        map('version', '2.0')
      ) AS classificacao,
      ai_extract(
        texto_status,
        '{"bloqueio": {"type": "string", "description": "o bloqueio em uma frase"},
          "quem_destrava": {"type": "string", "description": "quem precisa agir para destravar: área, pessoa ou fornecedor"},
          "dias_impacto": {"type": "number", "description": "dias de impacto no cronograma, 1 semana = 7"}}',
        map('version', '2.0')
      ) AS extracao
    FROM novos
    WHERE metodo = 'ia'
  ),

  com_ia AS (
    -- o resultado é VARIANT: lê-se com :response
    SELECT
      projeto_id,
      data_status,
      farol,
      classificacao:response[0]::STRING        AS causa_bloqueio,
      extracao:response:bloqueio::STRING       AS bloqueio,
      extracao:response:quem_destrava::STRING  AS quem_destrava,
      extracao:response:dias_impacto::DOUBLE   AS dias_impacto,
      metodo,
      texto_status
    FROM chamadas_ia
  ),

  sem_ia AS (
    SELECT
      projeto_id,
      data_status,
      farol,
      CASE
        WHEN status_vazio                                                            THEN 'nao_reportado'
        WHEN metodo = 'regra'                                                        THEN 'sem_bloqueio'
        WHEN texto RLIKE 'freeze|congelamento|janela de deploy'                      THEN 'change_freeze'
        WHEN texto RLIKE 'sre|infraestrutura|ambiente de homologação'                THEN 'falta_sre'
        WHEN texto RLIKE 'forge|consultoria|fornecedor'                              THEN 'dependencia_fornecedor'
        WHEN texto RLIKE 'saída de|rotatividade|onboarding'                          THEN 'rotatividade'
        WHEN texto RLIKE 'escopo|change request|regra de negócio'                    THEN 'mudanca_escopo'
        WHEN texto RLIKE 'bugs|regressão|refazendo'                                  THEN 'bug_retrabalho'
        WHEN texto RLIKE 'aprovação do cliente|homologação do cliente'               THEN 'aprovacao_cliente'
        ELSE 'nao_classificado'
      END                                  AS causa_bloqueio,
      CAST(NULL AS STRING)                 AS bloqueio,
      CAST(NULL AS STRING)                 AS quem_destrava,
      -- 'impacto estimado: 1 semana' = 7 dias, ou 'impacto estimado de N dias'
      CASE
        WHEN texto LIKE '%impacto estimado: 1 semana%' THEN 7.0
        ELSE CAST(nullif(regexp_extract(texto, 'impacto estimado de ([0-9]+) dias', 1), '') AS DOUBLE)
      END                                  AS dias_impacto,
      metodo,
      texto_status
    FROM novos
    WHERE metodo <> 'ia'
  )

  SELECT *, current_timestamp() AS _classificado_em FROM com_ia
  UNION ALL
  SELECT *, current_timestamp() AS _classificado_em FROM sem_ia
) s
ON t.projeto_id = s.projeto_id AND t.data_status = s.data_status
WHEN NOT MATCHED THEN INSERT *;


-- 3. Leitura: quantos status por método e causa
SELECT metodo, causa_bloqueio, count(*) AS status, round(sum(dias_impacto)) AS dias_impacto_declarados
FROM lakehouse_vertice.gold.status_estruturado
GROUP BY metodo, causa_bloqueio
ORDER BY metodo, status DESC;
