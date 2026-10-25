import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  AlertTitle,
  Badge,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import type { ReactNode } from 'react';
import { HOJE, fmtIndice, fmtInteiro, fmtPercentual, fmtReal, fmtRealCompacto } from '../../lib/formato';
import { useScoreEstouro } from '../../lib/score';

// Situação com cor semântica: crítico = vermelho (destructive), atenção = âmbar (warning)
function SeloSituacao({ situacao }: { situacao: string }) {
  if (situacao === 'crítico') return <Badge className="bg-destructive text-destructive-foreground">crítico</Badge>;
  if (situacao === 'atenção') return <Badge className="bg-warning text-warning-foreground">atenção</Badge>;
  return <Badge variant="outline">{situacao}</Badge>;
}

function Kpi({ titulo, valor, detalhe, carregando }: { titulo: string; valor: ReactNode; detalhe: string; carregando: boolean }) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardDescription>{titulo}</CardDescription>
        <CardTitle className="text-3xl tabular-nums">
          {carregando ? <Skeleton className="h-9 w-28" /> : valor}
        </CardTitle>
      </CardHeader>
      <CardContent className="text-xs text-muted-foreground">{detalhe}</CardContent>
    </Card>
  );
}

function Erro({ mensagem }: { mensagem: string }) {
  return (
    <Alert variant="destructive">
      <AlertTitle>Não deu para ler a gold</AlertTitle>
      <AlertDescription>{mensagem}</AlertDescription>
    </Alert>
  );
}

export function ProjetosRiscoPage() {
  const kpis = useAnalyticsQuery('kpis');
  const projetos = useAnalyticsQuery('projetos_risco');
  const score = useScoreEstouro();

  const k = kpis.data?.[0];
  const carregandoKpis = kpis.loading || !kpis.data;

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Projetos em risco</h2>
        <p className="text-sm text-muted-foreground">
          Carteira em andamento na fotografia de {HOJE} (gold.projeto_situacao_atual). SPI ou CPI abaixo de 0,9 =
          atenção, abaixo de 0,8 = crítico.
        </p>
      </div>

      {kpis.error && <Erro mensagem={String(kpis.error)} />}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Kpi
          titulo="Projetos em risco"
          carregando={carregandoKpis}
          valor={k ? `${Number(k.em_risco)} de ${Number(k.em_andamento)}` : '—'}
          detalhe={k ? `${Number(k.criticos)} críticos · ${Number(k.melancias)} melancias` : 'atenção + crítico'}
        />
        <Kpi
          titulo="Estouro previsto"
          carregando={carregandoKpis}
          valor={k ? fmtRealCompacto(k.estouro_previsto) : '—'}
          detalhe="Σ (EAC − orçamento) dos projetos que vão estourar"
        />
        <Kpi
          titulo="Carteira em andamento"
          carregando={carregandoKpis}
          valor={k ? fmtRealCompacto(k.carteira) : '—'}
          detalhe="Σ valor dos contratos"
        />
        <Kpi
          titulo="Alto risco em 30 dias"
          carregando={score.carregando}
          valor={score.disponivel && score.altoRisco !== null ? fmtInteiro(score.altoRisco) : '—'}
          detalhe={
            score.disponivel
              ? 'faixa alta do modelo (gold.score_estouro_30d)'
              : 'o modelo ainda não publicou o score'
          }
        />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Do pior para o melhor</CardTitle>
          <CardDescription>
            🍉 = melancia: farol do gerente verde com SPI abaixo de 0,9. A causa é a mais frequente no status dos
            últimos 90 dias.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {projetos.error && <Erro mensagem={String(projetos.error)} />}
          {projetos.loading && (
            <div className="space-y-2">
              {Array.from({ length: 6 }, (_, i) => (
                <Skeleton key={i} className="h-8 w-full" />
              ))}
            </div>
          )}
          {projetos.data && projetos.data.length === 0 && (
            <Empty>
              <EmptyHeader>
                <EmptyTitle>Nenhum projeto em andamento</EmptyTitle>
                <EmptyDescription>Confira se o job vertice_farol rodou e atualizou a gold.</EmptyDescription>
              </EmptyHeader>
            </Empty>
          )}
          {projetos.data && projetos.data.length > 0 && (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Projeto</TableHead>
                  <TableHead>Cliente</TableHead>
                  <TableHead>Situação</TableHead>
                  <TableHead className="text-right">SPI</TableHead>
                  <TableHead className="text-right">CPI</TableHead>
                  <TableHead className="text-right">Estouro previsto</TableHead>
                  <TableHead className="text-right">Atraso projetado</TableHead>
                  <TableHead>Farol do gerente</TableHead>
                  <TableHead>Farol pelo número</TableHead>
                  <TableHead>Causa (90 dias)</TableHead>
                  <TableHead className="text-right">P(estouro)</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {projetos.data.map((p) => {
                  const s = score.porProjeto.get(p.projeto_id);
                  return (
                    <TableRow key={p.projeto_id}>
                      <TableCell className="font-medium">{p.projeto}</TableCell>
                      <TableCell>{p.cliente}</TableCell>
                      <TableCell>
                        <SeloSituacao situacao={p.situacao} />
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{fmtIndice(p.spi)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmtIndice(p.cpi)}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmtReal(p.estouro_previsto)}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {Number(p.atraso_projetado_dias) > 0 ? `${fmtInteiro(p.atraso_projetado_dias)} dias` : '—'}
                      </TableCell>
                      <TableCell>
                        {p.farol_do_gerente ?? '—'}
                        {String(p.melancia) === 'true' && <span title="melancia"> 🍉</span>}
                      </TableCell>
                      <TableCell>{p.farol_calculado ?? '—'}</TableCell>
                      <TableCell className="text-muted-foreground">{p.causa_principal ?? '—'}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {s ? fmtPercentual(s.prob_estouro_30d) : '—'}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
