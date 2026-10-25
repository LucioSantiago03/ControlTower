-- Testes de qualidade da silver e da gold (sql_task, depois do medalhão).
-- Um teste por statement: cada um devolve uma linha (teste, obtido, esperado, resultado)
-- e, se falhar, para o job com raise_error dizendo o que olhar.
-- Atenção: a sql_task corta o arquivo em todo ponto e vírgula, então nenhuma mensagem ou comentário usa um.


-- 1. Os 60 projetos têm cronograma na silver.tarefas
WITH sem_cronograma AS (
  SELECT p.projeto_id
  FROM lakehouse_vertice.silver.projetos p
  LEFT ANTI JOIN lakehouse_vertice.silver.tarefas t ON t.projeto_id = p.projeto_id
)
SELECT '1 · os 60 projetos têm cronograma' AS teste,
       60 - count(*)                       AS obtido,
       60                                  AS esperado,
       CASE WHEN count(*) = 0 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 1 falhou: ', count(*), ' projeto(s) sem tarefas na silver.tarefas (',
                   concat_ws(', ', sort_array(collect_list(projeto_id))),
                   '). Olhe a bronze dessas ferramentas e o de-para em silver/02-tarefas.sql')) AS STRING)
       END AS resultado
FROM sem_cronograma;


-- 2. Cada projeto veio de UMA ferramenta, a do cadastro do PMO
WITH por_projeto AS (
  SELECT projeto_id, count(DISTINCT ferramenta) AS qtd_ferramentas, max(ferramenta) AS ferramenta
  FROM lakehouse_vertice.silver.tarefas
  GROUP BY projeto_id
),
errados AS (
  SELECT pp.projeto_id
  FROM por_projeto pp
  JOIN lakehouse_vertice.silver.projetos p ON p.projeto_id = pp.projeto_id
  WHERE pp.qtd_ferramentas <> 1 OR pp.ferramenta <> p.ferramenta
)
SELECT '2 · uma ferramenta por projeto, a do cadastro' AS teste,
       count(*) AS obtido,
       0        AS esperado,
       CASE WHEN count(*) = 0 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 2 falhou: projetos com tarefas de outra ferramenta ou de mais de uma (',
                   concat_ws(', ', sort_array(collect_list(projeto_id))), ')')) AS STRING)
       END AS resultado
FROM errados;


-- 3. As horas do Excel na silver = a soma das linhas de TOTAL das planilhas
WITH totais AS (
  SELECT
    (SELECT sum(CAST(replace(horas_previstas, 'h', '') AS DOUBLE))
       FROM lakehouse_vertice.bronze.excel_tarefas WHERE tarefa = 'TOTAL') AS horas_total_planilhas,
    (SELECT sum(horas)
       FROM lakehouse_vertice.silver.tarefas WHERE ferramenta = 'excel')   AS horas_silver
)
SELECT '3 · horas do Excel = linhas de TOTAL' AS teste,
       horas_silver          AS obtido,
       horas_total_planilhas AS esperado,
       CASE WHEN abs(horas_silver - horas_total_planilhas) < 0.01 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 3 falhou: silver tem ', horas_silver, ' horas do Excel e as linhas de TOTAL somam ',
                   horas_total_planilhas, '. Olhe o filtro do TOTAL e a limpeza das horas em silver/02-tarefas.sql')) AS STRING)
       END AS resultado
FROM totais;


-- 4. Uma linha por pessoa na silver
SELECT '4 · uma linha por pessoa' AS teste,
       count(*)                       AS obtido,
       count(DISTINCT colaborador_id) AS esperado,
       CASE WHEN count(*) = count(DISTINCT colaborador_id) THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 4 falhou: ', count(*) - count(DISTINCT colaborador_id),
                   ' pessoa(s) duplicada(s) na silver.colaboradores')) AS STRING)
       END AS resultado
FROM lakehouse_vertice.silver.colaboradores;


-- 5. A CodeForge virou um fornecedor só
SELECT '5 · CodeForge é um fornecedor só' AS teste,
       count(DISTINCT fornecedor) AS obtido,
       1                          AS esperado,
       CASE WHEN count(DISTINCT fornecedor) = 1 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 5 falhou: a CodeForge aparece com ', count(DISTINCT fornecedor),
                   ' grafias (', concat_ws(' | ', collect_set(fornecedor)), ')')) AS STRING)
       END AS resultado
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%';


-- 6. A limpeza não mudou o custo total (bronze com replace = silver)
WITH totais AS (
  SELECT
    (SELECT sum(CAST(replace(valor, ',', '.') AS DECIMAL(14, 2))) FROM lakehouse_vertice.bronze.custos) AS custo_bronze,
    (SELECT sum(valor) FROM lakehouse_vertice.silver.custos)                                            AS custo_silver
)
SELECT '6 · custo total bronze = silver' AS teste,
       custo_silver AS obtido,
       custo_bronze AS esperado,
       CASE WHEN custo_silver = custo_bronze THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 6 falhou: a bronze soma R$ ', custo_bronze, ' e a silver R$ ', custo_silver,
                   '. Algum valor virou NULL na conversão (silver/03-status-e-custos.sql)')) AS STRING)
       END AS resultado
FROM totais;


-- 7. Os 60 projetos têm fotografia de hoje
SELECT '7 · 60 projetos na fotografia de hoje' AS teste,
       count(*) AS obtido,
       60       AS esperado,
       CASE WHEN count(*) = 60 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 7 falhou: gold.projeto_situacao_atual tem ', count(*), ' linhas (esperado 60)')) AS STRING)
       END AS resultado
FROM lakehouse_vertice.gold.projeto_situacao_atual;


-- 8. Todo projeto em andamento tem SPI e CPI
WITH sem_indice AS (
  SELECT projeto_id
  FROM lakehouse_vertice.gold.projeto_situacao_atual
  WHERE status = 'em_andamento' AND (spi IS NULL OR cpi IS NULL)
)
SELECT '8 · em andamento com SPI e CPI' AS teste,
       count(*) AS obtido,
       0        AS esperado,
       CASE WHEN count(*) = 0 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 8 falhou: projetos em andamento sem SPI ou CPI (',
                   concat_ws(', ', sort_array(collect_list(projeto_id))), ')')) AS STRING)
       END AS resultado
FROM sem_indice;


-- 9. O EV de hoje do status semanal bate com o das ferramentas (diferença < 1%)
-- (carteira em andamento, só os projetos que têm EV nas duas fontes: quem não tem cronograma cai no teste 1)
WITH ev_hoje AS (
  SELECT sum(f.ev) AS ev_status, sum(s.ev) AS ev_ferramentas
  FROM lakehouse_vertice.gold.projeto_situacao_atual s
  JOIN lakehouse_vertice.gold.fato_projeto_semana f
    ON f.projeto_id = s.projeto_id AND f.semana = DATE'2026-10-16'
  WHERE s.status = 'em_andamento' AND s.ev IS NOT NULL AND f.ev IS NOT NULL
)
SELECT '9 · EV do status = EV das ferramentas' AS teste,
       round(abs(ev_status - ev_ferramentas) / ev_ferramentas * 100, 3) AS obtido,
       '< 1%'                                                           AS esperado,
       CASE WHEN abs(ev_status - ev_ferramentas) / ev_ferramentas < 0.01 THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 9 falhou: EV de hoje pelo status semanal R$ ', ev_status,
                   ' contra R$ ', ev_ferramentas, ' pelas ferramentas')) AS STRING)
       END AS resultado
FROM ev_hoje;


-- 10. O AC de hoje no fato = soma dos lançamentos até hoje
WITH totais AS (
  SELECT
    (SELECT sum(ac) FROM lakehouse_vertice.gold.fato_projeto_semana WHERE semana = DATE'2026-10-16') AS ac_fato,
    (SELECT sum(valor) FROM lakehouse_vertice.silver.custos WHERE data <= DATE'2026-10-16')          AS custo_ate_hoje
)
SELECT '10 · AC de hoje = lançamentos até hoje' AS teste,
       ac_fato        AS obtido,
       custo_ate_hoje AS esperado,
       CASE WHEN ac_fato = custo_ate_hoje THEN 'ok'
            ELSE CAST(raise_error(concat('Teste 10 falhou: o fato acumula R$ ', ac_fato, ' e os lançamentos somam R$ ',
                   custo_ate_hoje, '. Olhe a soma acumulada em gold/01-fato-projeto-semana.sql')) AS STRING)
       END AS resultado
FROM totais;
