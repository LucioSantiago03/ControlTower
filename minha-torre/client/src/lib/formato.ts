// Formatos em português. Tudo que vem do warehouse passa por Number() antes:
// o warehouse devolve número como string.

const real = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL', maximumFractionDigits: 0 });
const realCompacto = new Intl.NumberFormat('pt-BR', {
  style: 'currency',
  currency: 'BRL',
  notation: 'compact',
  maximumFractionDigits: 1,
});
const duasCasas = new Intl.NumberFormat('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const umaCasa = new Intl.NumberFormat('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const inteiro = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 0 });
const percentual = new Intl.NumberFormat('pt-BR', { style: 'percent', maximumFractionDigits: 0 });

function valido(v: unknown): v is number | string {
  return v !== null && v !== undefined && v !== '' && !Number.isNaN(Number(v));
}

export const fmtReal = (v: unknown) => (valido(v) ? real.format(Number(v)) : '—');
export const fmtRealCompacto = (v: unknown) => (valido(v) ? realCompacto.format(Number(v)) : '—');
export const fmtIndice = (v: unknown) => (valido(v) ? duasCasas.format(Number(v)) : '—');
export const fmtUmaCasa = (v: unknown) => (valido(v) ? umaCasa.format(Number(v)) : '—');
export const fmtInteiro = (v: unknown) => (valido(v) ? inteiro.format(Number(v)) : '—');
export const fmtPercentual = (v: unknown) => (valido(v) ? percentual.format(Number(v)) : '—');

/** O "hoje" do dataset: a fotografia da gold é de 16/10/2026. */
export const HOJE = '16/10/2026';
