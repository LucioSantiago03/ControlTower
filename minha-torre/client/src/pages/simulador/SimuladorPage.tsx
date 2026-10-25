import {
  useAnalyticsQuery,
  Alert,
  AlertDescription,
  AlertTitle,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
} from '@databricks/appkit-ui/react';
import { useMemo, useState } from 'react';
import { fmtIndice, fmtInteiro, fmtPercentual, fmtReal, fmtUmaCasa } from '../../lib/formato';

const SEMANAS_NO_MES = 4;
const DIAS_DA_JANELA = 90; // o status estruturado olha os últimos 90 dias
const DIAS_NO_MES = 30;

function Resultado({ titulo, valor, detalhe, destaque }: { titulo: string; valor: string; detalhe: string; destaque?: 'bom' | 'ruim' }) {
  const cor = destaque === 'bom' ? 'text-success' : destaque === 'ruim' ? 'text-destructive' : 'text-foreground';
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardDescription>{titulo}</CardDescription>
        <CardTitle className={`text-2xl tabular-nums ${cor}`}>{valor}</CardTitle>
      </CardHeader>
      <CardContent className="text-xs text-muted-foreground">{detalhe}</CardContent>
    </Card>
  );
}

export function SimuladorPage() {
  const pessoas = useAnalyticsQuery('pessoas_ociosas');
  const projetos = useAnalyticsQuery('projetos_risco');

  const [pessoaId, setPessoaId] = useState<string>('');
  const [destinoId, setDestinoId] = useState<string>('');
  const [horasOnboarding, setHorasOnboarding] = useState<number>(40);

  // a pessoa escolhida (ou a primeira da lista: a de maior custo ocioso)
  const pessoa = useMemo(() => {
    const lista = pessoas.data ?? [];
    return lista.find((p) => `${p.colaborador_id}|${p.projeto_id}` === pessoaId) ?? lista[0];
  }, [pessoas.data, pessoaId]);
  const ehSre = pessoa?.papel === 'sre';

  // destinos: só atenção ou crítico. Para SRE, quem mais sofre com falta de SRE vem primeiro.
  const destinos = useMemo(() => {
    const emRisco = (projetos.data ?? []).filter((p) => p.situacao === 'atenção' || p.situacao === 'crítico');
    if (!ehSre) return emRisco;
    return [...emRisco].sort((a, b) => Number(b.dias_falta_sre) - Number(a.dias_falta_sre));
  }, [projetos.data, ehSre]);
  const destino = destinos.find((d) => d.projeto_id === destinoId) ?? destinos[0];

  if (pessoas.error || projetos.error) {
    return (
      <Alert variant="destructive" className="max-w-3xl mx-auto">
        <AlertTitle>Não deu para ler a gold</AlertTitle>
        <AlertDescription>{String(pessoas.error ?? projetos.error)}</AlertDescription>
      </Alert>
    );
  }
  if (pessoas.loading || projetos.loading || !pessoas.data || !projetos.data) {
    return (
      <div className="space-y-4 max-w-5xl mx-auto">
        <Skeleton className="h-10 w-1/2" />
        <Skeleton className="h-32 w-full" />
      </div>
    );
  }
  if (!pessoa || !destino) {
    return (
      <Empty>
        <EmptyHeader>
          <EmptyTitle>{!pessoa ? 'Ninguém com menos de 20% de uso' : 'Nenhum projeto em atenção ou crítico'}</EmptyTitle>
          <EmptyDescription>Não há realocação para simular nas últimas 12 semanas.</EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }

  // ---- a conta (tudo com Number(): o warehouse devolve número como string)
  const horasSemana = Number(pessoa.horas_paradas_semana);
  const custoSemana = Number(pessoa.custo_ocioso_semana);
  const custoHora = Number(pessoa.custo_hora);
  const horasMes = horasSemana * SEMANAS_NO_MES;
  const ociosidadeEvitada = custoSemana * SEMANAS_NO_MES;

  const causa = ehSre ? 'falta_sre' : (destino.causa_principal ?? '');
  const diasDaCausa =
    causa === 'falta_sre' ? Number(destino.dias_falta_sre) : causa === 'rotatividade' ? Number(destino.dias_rotatividade) : 0;
  const diasRecuperados = (diasDaCausa / DIAS_DA_JANELA) * DIAS_NO_MES;

  const horasOnb = Number.isFinite(horasOnboarding) ? Math.max(0, horasOnboarding) : 0;
  const mobilizacao = horasOnb * custoHora;
  const saldo = ociosidadeEvitada - mobilizacao;

  return (
    <div className="space-y-6 w-full max-w-5xl mx-auto">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Simulador de realocação</h2>
        <p className="text-sm text-muted-foreground">
          Quem está parado (menos de 20% de uso nas últimas 12 semanas) pode destravar um projeto em atenção ou crítico?
        </p>
      </div>

      <Card>
        <CardContent className="grid grid-cols-1 md:grid-cols-3 gap-4 pt-6">
          <div className="space-y-2">
            <Label htmlFor="pessoa">Pessoa ociosa</Label>
            <Select
              value={`${pessoa.colaborador_id}|${pessoa.projeto_id}`}
              onValueChange={(v) => {
                setPessoaId(v);
                setDestinoId('');
              }}
            >
              <SelectTrigger id="pessoa">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {pessoas.data.map((p) => (
                  <SelectItem key={`${p.colaborador_id}|${p.projeto_id}`} value={`${p.colaborador_id}|${p.projeto_id}`}>
                    {p.nome} ({p.papel}, {p.projeto_id}) · uso {fmtPercentual(p.utilizacao)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="destino">Projeto destino {ehSre && '(ordenado por dias de falta de SRE)'}</Label>
            <Select value={destino.projeto_id} onValueChange={setDestinoId}>
              <SelectTrigger id="destino">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {destinos.map((d) => (
                  <SelectItem key={d.projeto_id} value={d.projeto_id}>
                    {d.projeto} · {d.situacao} · SPI {fmtIndice(d.spi)}
                    {ehSre && Number(d.dias_falta_sre) > 0 && ` · ${fmtInteiro(d.dias_falta_sre)} dias de falta de SRE`}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="onboarding">Horas de onboarding</Label>
            <Input
              id="onboarding"
              type="number"
              min={0}
              value={Number.isFinite(horasOnboarding) ? horasOnboarding : ''}
              onChange={(e) => setHorasOnboarding(e.target.valueAsNumber)}
            />
          </div>
        </CardContent>
      </Card>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Resultado titulo="Horas no mês" valor={`${fmtInteiro(horasMes)} h`} detalhe="horas paradas por semana × 4" />
        <Resultado
          titulo="Ociosidade que deixa de ser paga"
          valor={fmtReal(ociosidadeEvitada)}
          detalhe="custo ocioso por semana × 4"
        />
        <Resultado
          titulo="Cronograma recuperado"
          valor={`${fmtUmaCasa(diasRecuperados)} dias`}
          detalhe={causa ? `causa: ${causa}` : 'o destino não declarou bloqueio'}
        />
        <Resultado
          titulo="Saldo no mês"
          valor={fmtReal(saldo)}
          detalhe={`mobilização de ${fmtReal(mobilizacao)}`}
          destaque={saldo >= 0 ? 'bom' : 'ruim'}
        />
      </div>

      <details className="rounded-md border p-4 text-sm text-muted-foreground">
        <summary className="cursor-pointer font-medium text-foreground">Como a conta é feita</summary>
        <ol className="mt-3 list-decimal space-y-2 pl-5">
          <li>
            <strong>Horas no mês</strong> = {fmtUmaCasa(horasSemana)} h paradas por semana (média das últimas 12
            semanas) × {SEMANAS_NO_MES} = <strong>{fmtInteiro(horasMes)} h</strong>.
          </li>
          <li>
            <strong>Ociosidade que deixa de ser paga</strong> = {fmtReal(custoSemana)} de custo ocioso por semana ×{' '}
            {SEMANAS_NO_MES} = <strong>{fmtReal(ociosidadeEvitada)}</strong>. É dinheiro que a Vértice já paga hoje sem
            retorno.
          </li>
          <li>
            <strong>Cronograma recuperado</strong>: o {destino.projeto_id} declarou{' '}
            {fmtInteiro(diasDaCausa)} dias de impacto por <em>{causa || 'nenhuma causa'}</em> nos últimos{' '}
            {DIAS_DA_JANELA} dias. No ritmo de um mês: {fmtInteiro(diasDaCausa)} ÷ {DIAS_DA_JANELA} × {DIAS_NO_MES} ={' '}
            <strong>{fmtUmaCasa(diasRecuperados)} dias</strong>. O app só tem os dias de falta_sre e de rotatividade:
            outras causas contam 0.
          </li>
          <li>
            <strong>Mobilização</strong> = {fmtInteiro(horasOnb)} h de onboarding × {fmtReal(custoHora)} por hora ={' '}
            <strong>{fmtReal(mobilizacao)}</strong>.
          </li>
          <li>
            <strong>Saldo</strong> = {fmtReal(ociosidadeEvitada)} − {fmtReal(mobilizacao)} ={' '}
            <strong>{fmtReal(saldo)}</strong> no primeiro mês, sem contar o valor dos dias recuperados.
          </li>
        </ol>
      </details>
    </div>
  );
}
