// Godot SDK tests that need no network and no Manalens services (G-2525).
// CI runs this file. The Manalens monorepo runs it as `pnpm test:godot` on its pinned commit.
//
// 1. Mode `fixtures`: the shared fixture scenario against a capture server on
//    127.0.0.1. The request bodies must equal test_project/fixtures/request-*.json.
//    A changed body fails; run with UPDATE_FIXTURES=1 to write the new files,
//    then review the diff.
// 2. The modes in OFFLINE_MODES: each checks the queue in the process and sends
//    nothing (the endpoint is a closed port).
//
//   node test_project/run-tests.mjs              (GODOT=/path/to/godot when it is not on PATH)
//   UPDATE_FIXTURES=1 node test_project/run-tests.mjs
//
// Needs Godot 4.5 or later (the engine error capture) and Node 20 or later.
// The monorepo also runs tests/godot-sdk.test.mjs (the fixtures against the
// collector schema and the Unity fixtures) and `pnpm test:godot:local` (a real
// collector and Tinybird) on its pinned commit (CONTRIBUTING.md).
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = dirname(fileURLToPath(import.meta.url));
const folder = join(project, 'fixtures');
const godot = process.env.GODOT || 'godot';

const OFFLINE_MODES = [
  ['privacy', 'consent and reset clear the error history; engine messages are cleaned'],
  ['before_send', 'before_send gets every event and cannot break the envelope'],
  ['optout', 'set_consent(false) writes the opt-out marker and clears the ID'],
  ['corrupt', 'a config file that cannot be read: record nothing, keep the file'],
  ['marker', 'the opt-out marker wins when the config file is missing'],
  ['link', 'link_url() before and after consent'],
  ['session_age', 'a 24-hour session ends; properties are trimmed'],
  ['web_reload', 'a launch that ends without a quit, then a second launch'],
  ['disabled', 'enabled = false: no ID, no queue, no files'],
  ['overflow', 'send_failed(0, n) when the queue is over max_queue'],
  ['server', 'a server build sends no game_open or sessions unless track_server_builds'],
  ['auto_identify', 'auto_identify = steam: one hashed identify per launch, after consent, and the game wins'],
  ['platform', 'the platform option for console builds; console storefronts'],
  ['traits', 'traits(): anonymous and user traits, protected traits not sent, consent'],
  ['steam_link', 'link_steam() and steam_link: wait for the first accepted batch + 20 s, ticket, body, no retry of a refusal, one retry after a 429, consent and reset() during the wait'],
  ['batch_413', 'a 413 halves the batch and sends again at once; a 413 for 1 event drops it'],
  ['hang', 'a stuck main thread: game_hang once per stuck period, written while stuck; not unfocused or in the first frames; game_crash links to it'],
  ['steam_deck', 'SteamDeck=1: context.app.device is steam_deck, platform unchanged; without it the key is absent', { SteamDeck: '1' }],
];

// Each run gets this environment: without SteamDeck, so a run on a Steam Deck
// sends the same fixture bodies. A mode adds its own variables.
const baseEnv = { ...process.env };
delete baseEnv.SteamDeck;

function run(mode, endpoint, env = {}) {
  const args = ['--headless', '--path', project, '--', `--endpoint=${endpoint}`, '--publishable-key=mana_pk_fixture', `--mode=${mode}`];
  return new Promise((resolve, reject) => {
    const child = spawn(godot, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { ...baseEnv, ...env } });
    let text = '';
    child.stdout.on('data', chunk => { text += chunk; });
    child.stderr.on('data', chunk => { text += chunk; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 120_000);
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(timer);
      const line = text.split('\n').find(row => row.startsWith('MANALENS_RESULT '));
      const result = line ? JSON.parse(line.slice('MANALENS_RESULT '.length)) : null;
      if (!result?.ok) {
        console.error(text);
        reject(new Error(`the ${mode} mode failed: ${JSON.stringify(result?.failures ?? result?.error ?? `no MANALENS_RESULT, exit ${code}. Is Godot 4.5+ on PATH, or GODOT set?`)}`));
      } else resolve(result);
    });
  });
}

// A mode that must crash: it never prints MANALENS_RESULT and exits with an error.
function crash(mode, endpoint) {
  const args = ['--headless', '--path', project, '--', `--endpoint=${endpoint}`, '--publishable-key=mana_pk_fixture', `--mode=${mode}`];
  return new Promise((resolve, reject) => {
    const child = spawn(godot, args, { stdio: ['ignore', 'pipe', 'pipe'], env: baseEnv });
    let text = '';
    child.stdout.on('data', chunk => { text += chunk; });
    child.stderr.on('data', chunk => { text += chunk; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 120_000);
    child.on('error', reject);
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      if (text.includes('MANALENS_RESULT ') || !text.includes('Program crashed')) {
        console.error(text);
        reject(new Error(`the ${mode} mode did not crash (exit ${code}, signal ${signal})`));
      } else resolve();
    });
  });
}

// A mode whose main thread gets stuck for good: kill it 3 s after it says so,
// as a player kills a frozen game.
function killWhenStuck(mode, endpoint) {
  const args = ['--headless', '--path', project, '--', `--endpoint=${endpoint}`, '--publishable-key=mana_pk_fixture', `--mode=${mode}`];
  return new Promise((resolve, reject) => {
    const child = spawn(godot, args, { stdio: ['ignore', 'pipe', 'pipe'], env: baseEnv });
    let text = '';
    let killer = null;
    const onData = chunk => {
      text += chunk;
      if (!killer && text.includes('MANALENS_HANG_START')) killer = setTimeout(() => child.kill('SIGKILL'), 3_000);
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    const timer = setTimeout(() => child.kill('SIGKILL'), 30_000);
    child.on('error', reject);
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      clearTimeout(killer);
      if (text.includes('MANALENS_RESULT ') || signal !== 'SIGKILL') {
        console.error(text);
        reject(new Error(`the ${mode} mode was not killed while stuck (exit ${code}, signal ${signal})`));
      } else resolve();
    });
  });
}

// 1. Fixtures.
const bodies = [];
const server = createServer(async (request, response) => {
  let body = '';
  for await (const chunk of request) body += chunk;
  if (request.method === 'POST' && request.url === '/v0/events') bodies.push(body);
  response.writeHead(202, { 'content-type': 'application/json' }).end(JSON.stringify({ accepted: bodies.length }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  await run('fixtures', `http://127.0.0.1:${server.address().port}`);
} finally {
  server.close();
}

const expected = bodies.map((body, index) => ({ name: `request-${index + 1}.json`, body: `${body}\n` }));
if (process.env.UPDATE_FIXTURES === '1') {
  mkdirSync(folder, { recursive: true });
  for (const name of readdirSync(folder).filter(file => /^request-\d+\.json$/.test(file))) rmSync(join(folder, name));
  for (const { name, body } of expected) writeFileSync(join(folder, name), body);
  console.log(`wrote ${expected.length} fixtures to ${folder}`);
} else {
  const committed = existsSync(folder) ? readdirSync(folder).filter(file => /^request-\d+\.json$/.test(file)).sort() : [];
  const problems = [];
  if (committed.join() !== expected.map(item => item.name).sort().join()) problems.push(`files: committed [${committed}], sent [${expected.map(item => item.name)}]`);
  for (const { name, body } of expected) {
    if (existsSync(join(folder, name)) && readFileSync(join(folder, name), 'utf8') !== body) problems.push(`${name} changed`);
  }
  if (problems.length) {
    console.error(problems.join('\n'));
    console.error('Run UPDATE_FIXTURES=1 with this script and review the diff.');
    process.exit(1);
  }
  console.log(`godot sdk: ${expected.length} request bodies match the committed fixtures`);
}

// 2. Modes with no network: the endpoint is a closed port.
for (const [mode, note, env] of OFFLINE_MODES) {
  await run(mode, 'http://127.0.0.1:9', env);
  console.log(`godot sdk: ${mode} mode ok (${note})`);
}

// 3. Crash stacks (P-2831): a real crash in OS.crash(), then the next launch.
// SKIP_CRASH_TEST=1 leaves it out on a desktop where the OS shows a crash
// dialog for each run; CI always runs it.
if (process.env.SKIP_CRASH_TEST === '1') {
  console.log('godot sdk: crash_stack mode skipped (SKIP_CRASH_TEST=1)');
} else {
  await crash('crash_launch', 'http://127.0.0.1:9');
  const crashed = await run('crash_stack', 'http://127.0.0.1:9');
  console.log(`godot sdk: crash_stack mode ok (${crashed.crash.error_type}, top frame ${crashed.crash.stack.split('\n')[0]})`);
}

// 4. Hang detection (P-2833): a launch whose main thread is stuck for good is
// killed; the next launch sends the saved game_hang and links game_crash to it.
await killWhenStuck('hang_launch', 'http://127.0.0.1:9');
const hung = await run('hang_crash', 'http://127.0.0.1:9');
console.log(`godot sdk: hang_crash mode ok (game_crash hang_message_id ${hung.crash.hang_message_id})`);
