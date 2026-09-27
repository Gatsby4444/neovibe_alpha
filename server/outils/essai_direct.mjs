// Essai de bout en bout du DIRECT, contre le serveur local lancé
// (`bash outils/cargo.sh run -p nv-server`) et la base locale.
//
// Deux comptes neufs (A et B), une conversation entre eux :
//  1. A suit les messages de la conversation ; un message écrit dans la
//     base (comme par n'importe quel chemin) arrive chez A ;
//  2. B diffuse « en train d'écrire » : A le reçoit, B ne le reçoit pas ;
//  3. B ne peut PAS suivre une conversation dont il n'est pas membre ;
//  4. A renouvelle son badge sans couper la connexion.
// Tout est effacé à la fin.
//
// Usage :  node server/outils/essai_direct.mjs
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';

const BASE = process.env.NV_SERVEUR ?? 'http://127.0.0.1:8787';
const WS = BASE.replace('http', 'ws') + '/v1/direct';
const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
const sql = (q) => execFileSync('docker', ['exec', '-i', 'nv_rust_db', 'psql', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'nv_serveur'], { input: q, env }).toString().trim();

async function inscrire(nom) {
  const r = await fetch(`${BASE}/v1/auth/inscription`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: `${nom}.${randomBytes(4).toString('hex')}@essai.fr`, password: 'secret123', device_hash: randomBytes(32).toString('hex') }),
  });
  if (!r.ok) throw new Error(`inscription ${nom} : ${r.status} ${await r.text()}`);
  return r.json();
}

function ouvrir(jetons) {
  return new Promise((ok, ko) => {
    const ws = new WebSocket(WS);
    const recus = [];
    ws.onmessage = (m) => recus.push(JSON.parse(m.data));
    ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', token: jetons.access_token }));
    ws.onerror = (e) => ko(e);
    const attendre = (pred, ms = 5000) => new Promise((ok2, ko2) => {
      const debut = Date.now();
      const t = setInterval(() => {
        const i = recus.findIndex(pred);
        if (i >= 0) { clearInterval(t); ok2(recus.splice(i, 1)[0]); }
        else if (Date.now() - debut > ms) { clearInterval(t); ko2(new Error('rien reçu : ' + pred)); }
      }, 20);
    });
    attendre((m) => m.type === 'pret').then(() => ok({ ws, recus, attendre }), ko);
  });
}

const verifier = (cond, quoi) => { if (!cond) throw new Error('ÉCHEC : ' + quoi); console.log('ok   ' + quoi); };

const a = await inscrire('a');
const b = await inscrire('b');
const conv = randomUUID();
const idA = a.user.id, idB = b.user.id;
try {
  sql(`insert into public.profiles (id, display_name) values ('${idA}', 'essai.a.${idA.slice(0, 6)}'), ('${idB}', 'essai.b.${idB.slice(0, 6)}');
       insert into public.conversations (id, conversation_type) values ('${conv}', 'direct');
       insert into public.conversation_members (conversation_id, user_id, joined_at) values ('${conv}', '${idA}', now() - interval '1 minute'), ('${conv}', '${idB}', now() - interval '1 minute');`);
  const A = await ouvrir(a);
  const B = await ouvrir(b);

  A.ws.send(JSON.stringify({ type: 'abonner', ref: 'm', sujet: `messages:conversation_id=${conv}` }));
  await A.attendre((m) => m.type === 'abonne' && m.ref === 'm');
  A.ws.send(JSON.stringify({ type: 'abonner', ref: 't', sujet: `typing:${conv}` }));
  await A.attendre((m) => m.type === 'abonne' && m.ref === 't');
  B.ws.send(JSON.stringify({ type: 'abonner', ref: 't', sujet: `typing:${conv}` }));
  await B.attendre((m) => m.type === 'abonne' && m.ref === 't');

  sql(`insert into public.messages (conversation_id, sender_id, kind, body) values ('${conv}', '${idB}', 'text', 'bonjour du direct')`);
  const msg = await A.attendre((m) => m.type === 'changement' && m.ref === 'm');
  verifier(msg.op === 'INSERT' && msg.ligne.body === 'bonjour du direct', 'le message écrit en base arrive chez A');

  B.ws.send(JSON.stringify({ type: 'diffuser', sujet: `typing:${conv}`, contenu: { user_id: idB, name: 'B' } }));
  const d = await A.attendre((m) => m.type === 'diffusion' && m.ref === 't');
  verifier(d.contenu.name === 'B', '« en train d\'écrire » de B arrive chez A');
  await new Promise((r) => setTimeout(r, 400));
  verifier(!B.recus.some((m) => m.type === 'diffusion'), 'B ne reçoit pas sa propre diffusion');

  B.ws.send(JSON.stringify({ type: 'abonner', ref: 'x', sujet: `messages:conversation_id=${randomUUID()}` }));
  const refus = await B.attendre((m) => m.ref === 'x');
  verifier(refus.type === 'erreur', 'B ne peut pas suivre une conversation dont il n\'est pas membre');

  const r = await fetch(`${BASE}/v1/auth/renouveler`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ refresh_token: a.refresh_token }) });
  const a2 = await r.json();
  A.ws.send(JSON.stringify({ type: 'auth', token: a2.access_token }));
  await A.attendre((m) => m.type === 'pret');
  sql(`insert into public.messages (conversation_id, sender_id, kind, body) values ('${conv}', '${idB}', 'text', 'après renouvellement')`);
  const m2 = await A.attendre((m) => m.type === 'changement' && m.ligne?.body === 'après renouvellement');
  verifier(!!m2, 'le badge se renouvelle sans couper la connexion');

  A.ws.close(); B.ws.close();
  console.log('\nLe direct fonctionne de bout en bout.');
} finally {
  sql(`delete from public.conversations where id = '${conv}';
       delete from public.profiles where id in ('${idA}', '${idB}');
       delete from private.device_signups where user_id in ('${idA}', '${idB}');
       delete from auth.users where id in ('${idA}', '${idB}');`);
}
