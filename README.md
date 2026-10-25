# ControlTower · Projeto Farol

Uma torre de controle de projetos construída de ponta a ponta no **Databricks**: da ingestão dos dados
brutos até um **app com URL** em que a diretoria pergunta em português e recebe a resposta com o SQL.

Projeto técnico da **Imersão Jornada de Dados** (outubro de 2026). Tudo aqui é código: o lakehouse, o job,
o dashboard, as métricas governadas, o agente de IA (Genie) e o app são publicados com
**Declarative Automation Bundles** (DABs) a partir deste repositório.

---

## Sumário

- [O problema](#o-problema)
- [O que foi construído](#o-que-foi-construído)
- [Arquitetura](#arquitetura)
- [Estrutura do repositório](#estrutura-do-repositório)
- [Os dados: bronze, silver e gold](#os-dados-bronze-silver-e-gold)
- [Os KPIs](#os-kpis)
- [O job `vertice_farol`](#o-job-vertice_farol)
- [Dashboard, métricas governadas e Genie](#dashboard-métricas-governadas-e-genie)
- [O app `minha-torre`](#o-app-minha-torre)
- [Pré-requisitos](#pré-requisitos)
- [Como publicar do zero](#como-publicar-do-zero)
- [Scripts de apoio](#scripts-de-apoio)
- [Números de referência](#números-de-referência)
- [Limitações conhecidas](#limitações-conhecidas)
- [Armadilhas que custaram tempo](#armadilhas-que-custaram-tempo)
- [Créditos](#créditos)

---

## O problema

A **Vértice Tecnologia** (empresa fictícia) desenvolve e implanta sistemas para grandes clientes de varejo,
financeiro, saúde, logística e indústria: 60 projetos, 520 pessoas, R$ 305 mi de carteira. Cada gerente
controla o projeto numa ferramenta diferente (**20 em planilhas Excel, 25 no ClickUp, 15 no MS Project**) e
ninguém consegue dizer quais projetos estão atrasados.

O dono fez **quatro perguntas**, e a torre responde as quatro:

| # | Pergunta | Onde a resposta mora |
|---|---|---|
| 1 | Quais projetos estão atrasados, e de quais clientes? | SPI, CPI e situação em `gold.projeto_situacao_atual` |
| 2 | Quanto esse atraso vai me custar? | EAC, estouro previsto e margem em `gold.mv_projetos` |
| 3 | Tenho gente parada enquanto outro projeto pede gente? | Utilização do timesheet em `gold.utilizacao_pessoa_semana` + causa no status |
| 4 | O que vai dar errado no próximo mês? | Entregas de consultoria atrasadas + change freeze do varejo (Black Friday) |

> O "hoje" do dataset é **16/10/2026 (sexta)**. Nenhuma query usa `current_date()`: os números precisam bater
> com os de qualquer pessoa que rode o projeto, em qualquer dia.

---

## O que foi construído

| Camada | Entrega |
|---|---|
| **Ingestão** | Notebooks serverless: feriados pela BrasilAPI e os arquivos do data lake (Supabase Storage, protocolo S3) para o volume `bronze.raw` e 9 tabelas bronze |
| **Silver** | 7 tabelas limpas num pipeline declarativo (Lakeflow, SQL, serverless). As 3 ferramentas viram **um modelo só** em `silver.tarefas` |
| **Gold** | 3 tabelas de negócio no mesmo pipeline + `status_estruturado`, o texto livre do status semanal transformado em colunas com IA (`ai_classify` + `ai_extract`) |
| **Qualidade** | `EXPECT ... ON VIOLATION FAIL UPDATE` no pipeline + 10 testes de qualidade numa tarefa SQL |
| **Métricas** | Metric view `gold.mv_projetos`: a fórmula de cada KPI num lugar só |
| **Dashboard** | AI/BI "Projeto Farol · Portfólio", 3 páginas, gerado por script |
| **Agente** | Genie "Farol · Diretoria", gerado por script, com instruções, exemplos de SQL e benchmark |
| **App** | Databricks App (AppKit, React + TypeScript): Projetos em risco, Simulador de realocação e Perguntar (Genie) |
| **Orquestração** | Job `vertice_farol`, toda segunda às 6h (America/Sao_Paulo), uma execução por vez |

---

## Arquitetura

```
 job vertice_farol · toda segunda às 6h
 ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
 │ ingestao_feriados ──┐                                                                        │
 │                     ├── conferencia_bronze ── medalhao ──┬── testes_de_qualidade ──┐         │
 │ ingestao_data_lake ─┘   (sql_task)            (pipeline  └── status_com_ia ────────┴── metricas_governadas
 │ (notebooks)                                    Lakeflow)     (ai_classify +            (metric view)
 │                                                silver ×7      ai_extract)                       │
 │                                                gold ×3                                          │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
          │                                │                                     │
          ▼                                ▼                                     ▼
 Dashboard "Projeto Farol · Portfólio"   Genie "Farol · Diretoria"  ◀──── aba Perguntar
 (recurso do bundle, lê a gold)          (gold + mv_projetos + silver.entregas_fornecedor)
                                                                                 ▲
                                         App "Projeto Farol" (minha-torre/, bundle próprio)
                                         Projetos em risco · Simulador · Perguntar
```

- **Catálogo** `lakehouse_vertice`, com os schemas `bronze`, `silver` e `gold` e o volume `bronze.raw`.
- **Silver e gold no mesmo pipeline declarativo.** A silver usa o schema padrão do pipeline; a gold escreve
  com o nome completo (`lakehouse_vertice.gold.x`).
- **IA, testes e métricas como `sql_task`** no SQL warehouse, sempre com o nome completo das tabelas.
- **Dois bundles:** o `vertice` na raiz e o do app em `minha-torre/`. O bundle da raiz exclui `minha-torre/**`
  do sync, para não subir o `node_modules` do app.

---

## Estrutura do repositório

```
.
├── databricks.yml                  # bundle da raiz: variáveis, target dev, sync.exclude do app
├── CLAUDE.md                       # contexto do projeto (regras, sujeira, armadilhas, números)
├── resources/
│   ├── vertice.job.yml             # job vertice_farol (7 tarefas, agendamento, 1 run por vez)
│   ├── vertice_medalhao.pipeline.yml   # pipeline Lakeflow: src/silver/** + src/gold/**
│   ├── dashboard.dashboard.yml     # recurso do dashboard
│   ├── dashboard-portfolio.lvdash.json # gerado por scripts/gerar_dashboard.py
│   ├── genie.genie_space.yml       # recurso do Genie
│   └── farol.geniespace.json       # gerado por scripts/gerar_genie.py
├── src/
│   ├── ingestao/                   # notebooks: feriados (BrasilAPI) e data lake (S3)
│   ├── conferencia/                # contagem das 9 tabelas bronze contra o esperado
│   ├── silver/                     # 01-projetos · 02-tarefas · 03-status-e-custos · 04-pessoas · 05-fornecedores
│   ├── gold/                       # 01-fato-projeto-semana · 02-situacao-e-pessoas
│   ├── testes/testes.sql           # os 10 testes de qualidade
│   ├── ia/status_estruturado.sql   # texto do status → colunas (regra, IA, palavra-chave), MERGE incremental
│   └── metricas/metricas.sql       # metric view gold.mv_projetos
├── scripts/
│   ├── run_sql.py                  # roda um .sql statement a statement pela API
│   ├── gerar_dashboard.py          # gera o JSON do dashboard
│   ├── gerar_genie.py              # gera o JSON do Genie (inclui o score só se a tabela existir)
│   ├── genie.py                    # pergunta ao Genie e roda o benchmark
│   └── conceder-acesso.sh          # dá ao app acesso de leitura à gold e à silver
├── aulas/aula-04-produtos-de-dados-ia/prd/
│   ├── CLAUDE.md                   # contexto da noite 4 (app, métricas, Genie, modelo)
│   └── genie-benchmark-diretoria.json  # 20 perguntas com o SQL de referência
└── minha-torre/                    # o app (bundle próprio)
    ├── databricks.yml              # recurso do app: warehouse + Genie, escopo dashboards.genie
    ├── app.yaml                    # comando e variáveis de ambiente do app
    ├── config/queries/             # kpis · projetos_risco · pessoas_ociosas
    ├── server/server.ts            # analytics + genie + rota GET /api/score-estouro
    └── client/src/                 # telas React
```

---

## Os dados: bronze, silver e gold

### Bronze: o dado como chegou (com a sujeira)

| Tabela | Linhas | O que é |
|---|---:|---|
| `projetos` | 60 | cadastro do PMO: cliente, segmento, valor, orçamento, datas, ferramenta e o código na ferramenta |
| `status_semanal` | 3.911 | o status de toda sexta: % concluído, farol do gerente e texto livre com bloqueios |
| `excel_tarefas` | 1.663 | as 20 planilhas (tudo texto) |
| `clickup_tarefas` | 2.119 | as tarefas das 25 listas do ClickUp |
| `msproject_tarefas` | 1.260 | as `<Task>` dos 15 XML do MS Project |
| `colaboradores` | 523 | as 520 pessoas (3 duplicadas) |
| `apontamentos` | 30.883 | timesheet semanal: horas disponíveis × apontadas |
| `custos` | 23.640 | lançamentos de custo real |
| `entregas_fornecedor` | 640 | entregas das consultorias: prometido × entregue |

### Silver: limpa e integrada

A sujeira é proposital: são **18 tipos**, e a limpeza é o conteúdo do projeto. Alguns exemplos:

| Sujeira | Decisão |
|---|---|
| Data em `yyyy-MM-dd` e `dd/MM/yyyy` na mesma coluna | `coalesce(try_to_date(x,'yyyy-MM-dd'), try_to_date(x,'dd/MM/yyyy'))` |
| Data do Excel em texto **ou** número de série | `dd/MM/yyyy` se tem `/`; senão `date_add(DATE'1899-12-30', n)` |
| % do Excel em `'45%'`, `'10,5%'` ou `0.45`; 11 acima de 100 | normaliza, corta em 100 e marca `pct_veio_acima_de_100` |
| Linha de TOTAL no fim de cada planilha | sai da silver (e um teste confere que a soma bate com o TOTAL) |
| Tarefas-resumo do MS Project somando as de baixo | `WHERE Summary = 0` |
| A fase do MS Project está na hierarquia, não na tarefa | `last_value(... OVER (PARTITION BY arquivo ORDER BY UID))` |
| Vírgula decimal em `custos.valor` | `replace(',', '.')` **antes** do CAST (`try_cast` jogaria R$ 5,4 mi fora em silêncio) |
| A mesma consultoria escrita de 4 jeitos | normaliza para `CodeForge Consultoria Ltda` |
| Status vazio (`''`, `N/A`, `ver ata da reunião`) | **não descarta**: marca `status_vazio` |

A integração das três ferramentas mora em `silver.tarefas`: três `CREATE TEMPORARY VIEW` (uma por
ferramenta, todas com as mesmas colunas) e um `UNION ALL` numa materialized view.

**O teste de uma boa limpeza:** o custo total não muda (R$ 193,35 mi na bronze = R$ 193,35 mi na silver), e
as horas de cada planilha batem com a linha de TOTAL.

### Gold: pouca tabela, de propósito

| Tabela | O que é |
|---|---|
| `fato_projeto_semana` | o **filme**: projeto × sexta, do início até hoje, com PV, EV e AC **acumulados**, SPI, CPI, farol e horas |
| `projeto_situacao_atual` | a **fotografia** de hoje: cadastro + KPIs calculados sobre as tarefas das ferramentas, situação, farol do gerente × farol calculado, melancia |
| `utilizacao_pessoa_semana` | pessoa × projeto × semana: utilização, horas e custo ociosos, SPI do projeto naquela semana |
| `status_estruturado` | o texto do status em colunas: causa do bloqueio, bloqueio, quem destrava, dias de impacto |
| `mv_projetos` | metric view com as fórmulas governadas da carteira em andamento |

O histórico do avanço vem do **status semanal** (as ferramentas só guardam o % de hoje). Fornecedor não tem
tabela gold: lê-se direto da `silver.entregas_fornecedor`.

---

## Os KPIs

| KPI | Fórmula |
|---|---|
| **SPI** | EV ÷ PV. Nas tarefas: Σ horas × % concluído ÷ Σ horas × % do prazo baseline decorrido. Abaixo de 1 é atraso |
| **CPI** | EV ÷ AC, com EV = orçamento × horas agregadas ÷ horas totais. Abaixo de 1 é estouro |
| **EAC** | orçamento ÷ CPI |
| **Estouro previsto** | EAC − orçamento, só quando positivo |
| **Margem projetada** | (valor do contrato − EAC) ÷ valor do contrato |
| **Atraso projetado (dias)** | duração baseline ÷ SPI − duração baseline |
| **Farol calculado** | regra do manual: verde com SPI ≥ 0,95, amarelo ≥ 0,90, vermelho abaixo |
| **Melancia** | farol do gerente verde e SPI < 0,9 (verde por fora, vermelho por dentro) |

**Regras de corte:** SPI ou CPI abaixo de 0,9 = **atenção**; abaixo de 0,8 = **crítico**.
Razão da carteira é sempre **SUM ÷ SUM**, nunca média de razão.

---

## O job `vertice_farol`

| # | Tarefa | Tipo | O que faz |
|---|---|---|---|
| 1 | `ingestao_feriados` | notebook | feriados da BrasilAPI → `bronze.feriados` |
| 2 | `ingestao_data_lake` | notebook | arquivos do data lake (boto3, S3) → volume `bronze.raw` → 9 tabelas bronze |
| 3 | `conferencia_bronze` | SQL | a bronze chegou inteira? (contagem contra o esperado; para o job se divergir) |
| 4 | `medalhao` | pipeline | silver ×7 e gold ×3 (com `EXPECT ... FAIL UPDATE`) |
| 5 | `testes_de_qualidade` | SQL | 10 testes sobre silver e gold, cada um com `raise_error` |
| 6 | `status_com_ia` | SQL | o texto do status vira coluna: regra para "sem bloqueio", IA nos últimos 90 dias com bloqueio, palavra-chave no histórico. `MERGE` incremental: a IA nunca reclassifica um status |
| 7 | `metricas_governadas` | SQL | recria a metric view `gold.mv_projetos` |

- Agendamento: **toda segunda às 6h** (America/Sao_Paulo). No target `dev` o preset deixa o agendamento pausado.
- `max_concurrent_runs: 1`: duas execuções ao mesmo tempo apagariam a bronze uma da outra.

**Os 10 testes de qualidade:** os 60 projetos têm cronograma · cada projeto veio de uma ferramenta só, a do
cadastro · horas do Excel = linhas de TOTAL · uma linha por pessoa · a CodeForge virou um fornecedor só · a
limpeza não mudou o custo total · 60 projetos na fotografia de hoje · todo projeto em andamento tem SPI e CPI ·
EV do status semanal = EV das ferramentas (diferença < 1%) · AC de hoje no fato = lançamentos até hoje.

---

## Dashboard, métricas governadas e Genie

### Dashboard "Projeto Farol · Portfólio"

Gerado por `scripts/gerar_dashboard.py` (AI/BI, `GRID_V1`), com três páginas. Cada página tem como título a
pergunta do dono que ela responde.

- **Portfólio:** 7 KPIs da carteira, estouro previsto por projeto, dispersão SPI × CPI, SPI e CPI semanais e
  a tabela dos projetos com farol do gerente × farol calculado.
- **Pessoas:** top 15 por custo da hora parada, utilização por pessoa e projeto e as causas de bloqueio dos
  últimos 90 dias.
- **Fornecedores:** prazo real ÷ prometido, % no prazo e as entregas em atraso hoje.

### Métricas governadas (`gold.mv_projetos`)

Metric view em YAML (versão 1.1) sobre `projeto_situacao_atual`, filtrada nos projetos em andamento. Tem 9
dimensões e 11 medidas (`spi`, `cpi`, `eac`, `estouro_previsto`, `margem_projetada`, `projetos_em_risco`,
`projetos_criticos`, `projetos_melancia`…), com `comment` e `synonyms` em português para o Genie.

```sql
SELECT MEASURE(spi), MEASURE(cpi), MEASURE(estouro_previsto)
FROM lakehouse_vertice.gold.mv_projetos
```

### Genie "Farol · Diretoria"

Gerado por `scripts/gerar_genie.py` (`serialized_space` versão 2):

- **Fontes:** 4 tabelas gold, `silver.entregas_fornecedor` e a metric view `mv_projetos`.
- **Instruções:** quem pergunta, o "hoje", as fórmulas e cortes, onde buscar cada resposta, farol e melancia,
  "por que o projeto X atrasou", gente parada, fornecedor e "o que vai dar errado no próximo mês" (entregas
  atrasadas + change freeze do varejo de 01/11/2026 a 10/01/2027).
- **Exemplos de SQL:** um para cada pergunta do dono.
- **Score do modelo:** `gold.score_estouro_30d` só entra se a tabela existir no workspace (o script confere).

---

## O app `minha-torre`

Databricks App em **AppKit** (Node.js + React + TypeScript), com bundle próprio.

| Tela | O que mostra |
|---|---|
| **Projetos em risco** | 4 KPIs (em risco, estouro previsto, carteira, alto risco em 30 dias) e a tabela do pior para o melhor: situação com cor, farol do gerente com 🍉 nas melancias, a causa mais frequente no status dos últimos 90 dias e a probabilidade de estouro (quando o modelo existir) |
| **Simulador** | escolhe uma pessoa ociosa e um projeto em atenção ou crítico e calcula horas no mês, ociosidade evitada, dias de cronograma recuperados, custo de mobilização e saldo, com a conta explicada passo a passo |
| **Perguntar** | o Genie "Farol · Diretoria" dentro do app (`<GenieChat>`), rodando em nome de quem está logado |

- **Leitura:** `config/queries/*.sql` no SQL warehouse, com os tipos gerados pelo typegen.
- **Score do modelo:** lido pela rota `GET /api/score-estouro`, que responde `{disponivel: false}` quando a
  tabela não existe. Assim a falta dela não quebra o build, e a tela mostra "—".
- **Acesso:** o app é um usuário do Unity Catalog (service principal) e nasce **sem acesso**: rode
  `scripts/conceder-acesso.sh` depois do primeiro deploy.

---

## Pré-requisitos

- Um workspace **Databricks** (o projeto foi feito no **Free Edition**) com o catálogo `lakehouse_vertice`, os
  schemas `bronze`, `silver` e `gold` e o volume `bronze.raw`.
- **Databricks CLI** com suporte a bundles e apps (testado na v1.22) e um perfil configurado
  (`databricks auth login`).
- **Python 3.12** (os scripts usam só a biblioteca padrão e a CLI). O `pyproject.toml` traz o ambiente local
  do Databricks Connect, gerenciado com `uv`.
- **Node.js** (testado no 24 LTS) e **npm**, para o app.
- **Bash** (no Windows, o Git Bash) para o `conceder-acesso.sh`.
- As chaves do data lake (Supabase Storage, S3).

---

## Como publicar do zero

Troque `<perfil>` pelo nome do seu perfil da CLI (`databricks auth profiles` lista os perfis).

### 1. As chaves do data lake (fora do Git)

O repositório é público: as chaves **nunca** vão para um arquivo versionado. Crie
`.databricks/bundle/dev/variable-overrides.json` (o `.gitignore` já deixa a pasta de fora):

```json
{
  "s3_access_key_id": "<sua chave>",
  "s3_secret_access_key": "<seu segredo>"
}
```

Para rodar os notebooks localmente, copie `.env.example` para `.env` e preencha.

### 2. O bundle da raiz

O Genie precisa das tabelas existindo, inclusive a metric view. Do zero, a ordem é **deploy → run → deploy**:

```bash
databricks bundle validate --profile <perfil>
databricks bundle deploy   --profile <perfil>
databricks bundle run vertice_farol --profile <perfil>   # cria bronze, silver, gold e mv_projetos
python scripts/gerar_genie.py --profile <perfil>          # regenera o Genie (com ou sem score)
databricks bundle deploy   --profile <perfil>             # publica o Genie
databricks bundle summary  --profile <perfil>             # URLs do job, pipeline, dashboard e Genie
```

Para rodar só uma parte do job: `--only medalhao+` (o medalhão e tudo o que vem depois) ou
`--only metricas_governadas`.

> Depois do primeiro deploy, pause o agendamento de qualquer outro job que também recarregue a bronze.

### 3. O app

Pegue o id do Genie no `bundle summary` e coloque em `minha-torre/databricks.yml` (variáveis
`genie_space_id` e `genie_space_name`), junto com o id do seu warehouse (`databricks warehouses list`).

```bash
cd minha-torre
npm install
npm run typecheck && npm run lint
databricks apps validate --profile <perfil>
databricks bundle deploy --profile <perfil>              # cria o app e o service principal
bash ../scripts/conceder-acesso.sh <perfil> minha-torre  # USE CATALOG + USE SCHEMA/SELECT na gold e silver
databricks apps deploy  --profile <perfil>               # sobe o código e inicia o app
databricks apps get minha-torre --profile <perfil>       # estado e URL
```

O primeiro `bundle deploy` do app termina com erro de build (`INSUFFICIENT_PERMISSIONS`). Isso é esperado:
o service principal ainda não tem acesso, e o `conceder-acesso.sh` resolve. A primeira visita à aba
**Perguntar** pede consentimento OAuth para o app usar o Genie em seu nome.

> O Free Edition aceita no máximo **3 apps** por workspace. Confira com `databricks apps list`.

---

## Scripts de apoio

| Script | Uso |
|---|---|
| `scripts/run_sql.py` | `python scripts/run_sql.py <arquivo.sql> --profile <perfil> [--continuar]`. Roda statement a statement pela API de statements e mantém a indentação (necessária no YAML da metric view). `--continuar` segue depois de uma falha, útil para ver os 10 testes de uma vez |
| `scripts/gerar_dashboard.py` | `python scripts/gerar_dashboard.py [--sql conferencia.sql]`. Gera o JSON do dashboard. `--sql` também escreve cada query com o nome completo das tabelas, para conferir com `run_sql.py` |
| `scripts/gerar_genie.py` | `python scripts/gerar_genie.py --profile <perfil>` (ou `--sem-score`). Gera o JSON do Genie |
| `scripts/genie.py` | `python scripts/genie.py perguntar "Farol · Diretoria" "<pergunta>" --profile <perfil>` e `python scripts/genie.py benchmark "Farol · Diretoria" aulas/aula-04-produtos-de-dados-ia/prd/genie-benchmark-diretoria.json --profile <perfil>` |
| `scripts/conceder-acesso.sh` | `bash scripts/conceder-acesso.sh <perfil> [app] [warehouse_id]`. GRANTs para o service principal do app |

---

## Números de referência

Com o dataset completo (seed 42), estes números servem de teste:

| O que | Valor |
|---|---|
| Tarefas na silver | 4.917: Excel 1.643 (20 projetos), ClickUp 2.119 (25), MS Project 1.155 (15) |
| Projetos em andamento | 41 (19 concluídos) |
| Projetos críticos / em atenção | 7 / 10 |
| Estouro previsto (em andamento) | R$ 6,47 mi |
| SPI / CPI da carteira | 0,92 / 0,97 |
| Melancias | 4: PRJ-012, PRJ-028, PRJ-034, PRJ-042 |
| Custo real total | R$ 193,35 mi |
| Entregas em atraso | 5, todas da CodeForge (prazo real ÷ prometido 1,41, 0% no prazo) |
| SREs com menos de 20% de uso (12 semanas) | COL0017 e COL0018, no PRJ-007 (5,8% e 5,5%) |
| PRJ-011: causa no status (90 dias) | falta de SRE, 12 semanas, 57 dias de impacto declarado |
| Status classificados pela IA | 163 |
| Simulador COL0017 (PRJ-007) → PRJ-011 | 151 h no mês · R$ 30,1 mil de ociosidade evitada · 19,0 dias recuperados · onboarding R$ 8,0 mil · saldo R$ 22,1 mil |

---

## Limitações conhecidas

- **Bronze do Excel incompleta.** As planilhas do PRJ-020 e do PRJ-021 têm acento no nome e não chegam ao
  volume `bronze.raw` (1.500 de 1.663 linhas). Por isso:
  - a `conferencia_bronze` e os testes 1 e 8 falham;
  - a `metricas_governadas` fica pulada no job completo (ela depende dos testes);
  - os números ficam um pouco abaixo da referência: 7 críticos / 9 em atenção, estouro de R$ 4,42 mi, SPI 0,91.

  Para fechar: corrigir o upload dos nomes acentuados no notebook de ingestão e fazer o notebook ler as chaves
  com `dbutils.widgets` (hoje ele usa `.env` e não recebe os parâmetros do job).
- **CPI com o mesmo grupo dos dois lados.** No dashboard e na metric view, o CPI soma o AC só dos projetos que
  têm EV. Sem isso, os dois projetos sem cronograma entrariam com custo e sem avanço, e o CPI cairia para 0,84.
  Com a bronze completa, as duas contas dão o mesmo número.
- **O modelo de estouro em 30 dias** (`gold.score_estouro_30d`) não foi construído. O app e o Genie já estão
  preparados para ele: basta a tabela existir.
- **Benchmark do Genie: 17/20.** As perguntas 4 e 5 do benchmark filtram por `projeto = 'PRJ-011'`, mas nesta
  gold a coluna `projeto` é "código · nome", então a referência volta vazia. A 14 errou a caixa do valor
  (`'Excel'` em vez de `'excel'`).

---

## Armadilhas que custaram tempo

A lista completa, com o que fazer em cada caso, está no [CLAUDE.md](CLAUDE.md). As principais:

- `EXPECT` sobre valor NULL conta como violação, e o pipeline com `FAIL UPDATE` refaz o update até 5 vezes
  antes de desistir. Leia o erro na hora com `databricks pipelines list-pipeline-events <id> --filter "level='ERROR'"`.
- A `sql_task` corta o arquivo em **todo ponto e vírgula**, inclusive dentro do YAML da metric view e em comentários.
- `ai_classify` versão 2.0 devolve uma lista: leia com `:response[0]::STRING`. Filtre as linhas que vão para a
  IA num CTE, nunca dentro de um `CASE`.
- Função de janela dentro de agregação dá erro no pipeline: calcule a janela num CTE e agregue no seguinte.
- No dashboard, a gold vai com o nome **puro** da tabela (catálogo e schema vêm do recurso) e a silver com o nome **completo**.
- O app nasce sem acesso ao Unity Catalog, e o build falha no typegen até o `conceder-acesso.sh` rodar.
- Uma tabela que pode não existir não vai para `config/queries/` (quebra o build): leia por uma rota do servidor.
- O warehouse devolve número como string: `Number()` em tudo antes de formatar.
- No Windows: o `apps init` usa pnpm por padrão (`--package-manager npm`), o Git Bash converte `/api/...` em
  caminho do Windows (`MSYS_NO_PATHCONV=1`), e o PowerShell 5.1 grava BOM em arquivos de texto, o que quebra o SQL.

---

## Créditos

Projeto construído durante a **Imersão Jornada de Dados** (outubro de 2026), a partir do roteiro e do dataset
do curso ([lvgalvao/ImersaoControlTower](https://github.com/lvgalvao/ImersaoControlTower)). A Vértice Tecnologia,
seus clientes, pessoas e projetos são fictícios. O código foi escrito com o Claude Code, guiado pelo `CLAUDE.md`.
