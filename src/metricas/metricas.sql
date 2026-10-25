-- gold.mv_projetos: a fórmula de cada KPI da carteira num lugar só (metric view).
-- O dashboard, o Genie e o app perguntam "qual o SPI da carteira" e recebem a MESMA conta.
-- Razão é SUM/SUM, nunca média de razão. Fonte: a fotografia de hoje (16/10/2026), só em andamento.
--
-- ATENÇÃO: a sql_task do job corta o arquivo em todo ponto e vírgula, inclusive dentro do YAML.
-- Nenhum ponto e vírgula daqui para baixo, nem em comment. E o YAML precisa da indentação intacta.
CREATE OR REPLACE VIEW lakehouse_vertice.gold.mv_projetos
WITH METRICS
LANGUAGE YAML
COMMENT 'Métricas governadas da carteira em andamento da Vértice (fotografia de 16/10/2026): SPI, CPI, EAC, estouro previsto, margem projetada, atraso e contagens de projetos em risco, críticos e melancias. Use para totais da carteira, por cliente, segmento, ferramenta ou gerente.'
AS $$
version: 1.1
source: lakehouse_vertice.gold.projeto_situacao_atual
filter: status = 'em_andamento'
comment: "Carteira em andamento da Vértice na fotografia de 16/10/2026. Uma linha por projeto."

dimensions:
  - name: projeto_id
    expr: projeto_id
    comment: "Código do projeto, no formato PRJ-000"
    synonyms: ["código do projeto", "id do projeto"]
  - name: projeto
    expr: projeto
    comment: "Código e nome do projeto, como PRJ-011 · Nome"
    synonyms: ["nome do projeto"]
  - name: cliente
    expr: cliente
    synonyms: ["empresa cliente", "conta"]
  - name: segmento
    expr: segmento
    comment: "Segmento do cliente: varejo, financeiro, saúde, logística ou indústria"
    synonyms: ["setor", "vertical"]
  - name: ferramenta
    expr: ferramenta
    comment: "Onde o gerente controla o cronograma: excel, clickup ou msproject"
    synonyms: ["ferramenta de gestão", "sistema do cronograma"]
  - name: situacao
    expr: situacao
    comment: "crítico se SPI ou CPI abaixo de 0,8, atenção se abaixo de 0,9, senão ok"
    synonyms: ["status de risco", "classificação"]
  - name: farol_do_gerente
    expr: farol_do_gerente
    comment: "Farol que o gerente declarou no último status semanal: verde, amarelo ou vermelho"
    synonyms: ["farol declarado", "farol informado"]
  - name: farol_calculado
    expr: farol_calculado
    comment: "Farol pela regra do manual: verde com SPI a partir de 0,95, amarelo a partir de 0,90, senão vermelho"
    synonyms: ["farol pelo número", "farol real"]
  - name: gerente_projeto
    expr: gerente_projeto
    synonyms: ["gerente", "GP", "responsável"]

measures:
  - name: projetos
    expr: COUNT(1)
    comment: "Número de projetos em andamento"
    synonyms: ["quantidade de projetos", "total de projetos"]
  - name: carteira
    expr: SUM(valor_contrato)
    comment: "Soma do valor dos contratos, em reais"
    synonyms: ["valor da carteira", "valor contratado", "receita contratada"]
  - name: spi
    expr: SUM(ev) / SUM(pv)
    comment: "Índice de prazo: valor agregado dividido pelo valor planejado. Abaixo de 1 é atraso"
    synonyms: ["índice de desempenho de prazo", "schedule performance index"]
  - name: cpi
    expr: SUM(ev) / SUM(ac) FILTER (WHERE ev IS NOT NULL)
    comment: "Índice de custo: valor agregado dividido pelo custo real, só dos projetos com avanço medido. Abaixo de 1 é estouro"
    synonyms: ["índice de desempenho de custo", "cost performance index"]
  - name: eac
    expr: SUM(eac)
    comment: "Custo final estimado (orçamento dividido pelo CPI), em reais"
    synonyms: ["estimativa no término", "custo previsto no fim"]
  - name: estouro_previsto
    expr: SUM(estouro_previsto)
    comment: "Quanto o custo final vai passar do orçamento (EAC menos orçamento, só quando positivo), em reais"
    synonyms: ["estouro", "sobrecusto previsto", "quanto o atraso vai custar"]
  - name: margem_projetada
    expr: (SUM(valor_contrato) FILTER (WHERE eac IS NOT NULL) - SUM(eac)) / SUM(valor_contrato) FILTER (WHERE eac IS NOT NULL)
    comment: "Margem no fim do projeto: contrato menos EAC, dividido pelo contrato. Fração de 0 a 1"
    synonyms: ["margem", "margem prevista"]
  - name: atraso_projetado_medio_dias
    expr: AVG(atraso_projetado_dias)
    comment: "Atraso médio projetado, em dias corridos (duração baseline dividida pelo SPI menos a duração baseline)"
    synonyms: ["atraso médio", "dias de atraso"]
  - name: projetos_em_risco
    expr: COUNT(1) FILTER (WHERE situacao IN ('atenção', 'crítico'))
    comment: "Projetos em atenção ou críticos"
    synonyms: ["em risco", "projetos atrasados"]
  - name: projetos_criticos
    expr: COUNT(1) FILTER (WHERE situacao = 'crítico')
    comment: "Projetos com SPI ou CPI abaixo de 0,8"
    synonyms: ["críticos"]
  - name: projetos_melancia
    expr: COUNT(1) FILTER (WHERE melancia)
    comment: "Projetos com farol do gerente verde e SPI abaixo de 0,9: verde por fora, vermelho por dentro"
    synonyms: ["melancias", "farol verde atrasado"]
$$
