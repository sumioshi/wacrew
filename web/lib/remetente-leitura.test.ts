import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

// Mensagem recebida em DM pode estar gravada com `sender` vazio. Quem escreveu é o
// outro lado da conversa (o `groupJid`); em grupo não dá para saber, fica como está.
let tmp: string;
let data: typeof import('./data');
let contatos: typeof import('./contacts');
let inbox: typeof import('./inbox');

const DM = '5511900000002@s.whatsapp.net';
const GRUPO = '120363000000000001@g.us';
const linha = (o: Record<string, unknown>) =>
  `${JSON.stringify({ type: 'text', quotedText: null, mediaPath: null, ...o })}\n`;

beforeAll(async () => {
  tmp = await mkdtemp(join(tmpdir(), 'wa-remetente-'));
  const dir = join(tmp, 'data');
  await mkdir(join(dir, 'dm-5511900000002'), { recursive: true });
  await mkdir(join(dir, 'grupo-b'), { recursive: true });
  await mkdir(join(dir, 'backfill'), { recursive: true });
  const base = { group: 'Teste', groupJid: GRUPO, sender: DM, senderName: 'Cliente' };
  await writeFile(
    join(dir, 'backfill', 'messages.jsonl'),
    linha({ ...base, id: 'recente', timestamp: '2026-10-08T12:05:00.000Z' }) +
      linha({ ...base, id: 'recente-2', timestamp: '2026-10-08T12:05:00.000Z' }) +
      linha({ ...base, id: 'antiga', timestamp: '2026-10-08T12:00:00.000Z' }),
  );
  await writeFile(
    join(dir, 'backfill', 'calls.jsonl'),
    linha({ callId: 'C1', timestamp: '2026-10-08T12:03:00.000Z', from: DM, fromName: 'Cliente' }),
  );
  await writeFile(
    join(dir, 'dm-5511900000002', 'messages.jsonl'),
    linha({
      id: 'A1',
      timestamp: '2026-10-08T12:00:00Z',
      group: 'Fulano',
      groupJid: DM,
      sender: '5511888888888@s.whatsapp.net',
      senderName: 'Você',
      fromMe: true,
      text: 'opa',
    }) +
      linha({
        id: 'A2',
        timestamp: '2026-10-08T12:01:00Z',
        group: 'Fulano',
        groupJid: DM,
        sender: '',
        senderName: 'Fulano Souza',
        fromMe: false,
        text: 'beleza',
      }),
  );
  await writeFile(
    join(dir, 'grupo-b', 'messages.jsonl'),
    linha({
      id: 'B1',
      timestamp: '2026-10-08T12:00:00Z',
      group: 'Grupo B',
      groupJid: GRUPO,
      sender: '',
      senderName: '',
      fromMe: false,
      text: 'oi',
    }),
  );
  // O contato da DM é do time.
  await writeFile(join(dir, '.team.json'), JSON.stringify(['5511900000002']));
  process.env.WAC_DATA_DIR = dir;
  data = await import('./data');
  contatos = await import('./contacts');
  inbox = await import('./inbox');
});

describe('ordenação do histórico recuperado', () => {
  it('ordena mensagens antes de montar a janela e preserva a ordem dentro do mesmo segundo', async () => {
    expect((await data.readGroupRecords('backfill')).map((m) => m.id)).toEqual(['antiga', 'recente', 'recente-2']);
    expect((await data.readGroupMessages('backfill', { limit: 2 })).map((m) => m.id)).toEqual(['recente', 'recente-2']);
  });

  it('traz a mensagem antiga e a chamada anterior na página certa', async () => {
    const pagina = await data.readGroupMessages('backfill', { before: 'recente', limit: 2 });
    expect(pagina.map((m) => m.id)).toEqual(['antiga', 'call:C1']);
    expect(await data.readGroupMessages('backfill', { before: 'antiga', limit: 2 })).toEqual([]);
  });
});

afterAll(async () => {
  await rm(tmp, { recursive: true, force: true });
});

describe('remetente vazio na leitura', () => {
  it('recebida em DM fica com o outro lado da conversa', async () => {
    const [minha, dele] = await data.readGroupRecords('dm-5511900000002');
    expect(minha?.sender).toBe('5511888888888@s.whatsapp.net');
    expect(dele?.sender).toBe(DM);
  });

  it('em grupo continua vazio', async () => {
    const [m] = await data.readGroupRecords('grupo-b');
    expect(m?.sender).toBe('');
  });

  it('o nome do contato da DM entra no índice', async () => {
    const c = await contatos.buildContacts();
    expect(c.names.get('5511900000002')).toBe('Fulano Souza');
  });

  it('mensagem do time na DM não conta como cliente esperando', async () => {
    const c = await contatos.buildContacts();
    const registros = await data.readGroupRecords('dm-5511900000002');
    expect(inbox.evaluateGroup(registros, c)).toBeNull();
  });
});
