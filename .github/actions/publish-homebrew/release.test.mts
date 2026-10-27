import assert from 'node:assert/strict';
import { test } from 'node:test';
import { finalizeHomebrew, prepareHomebrew, renderCask } from './release.mts';
import type { HomebrewRelease } from './release.mts';

function release(version = '0.9.7', sha256 = 'a'.repeat(64)): HomebrewRelease {
  return {
    version,
    sha256,
    downloadUrl: `https://github.com/codex-ecosystem/codex-agent-bar/releases/download/v${version}/AgentBar-${version}.dmg`,
  };
}

function tap(initial?: string) {
  let content = initial;
  let revision = 0;
  let failure = 0;
  const requests: string[] = [];
  const request: typeof fetch = async (input, init) => {
    const url = String(input);
    const method = init?.method ?? 'GET';
    requests.push(`${method} ${url}`);
    assert.ok(url.startsWith('https://api.github.com/repos/codex-ecosystem/homebrew-tap/contents/Casks/codex-agent-bar.rb'));
    assert.equal(new Headers(init?.headers).get('Authorization'), 'Bearer test-token');
    if (failure) return new Response('{}', { status: failure });
    if (method === 'GET') {
      if (content === undefined) return new Response('{}', { status: 404 });
      return Response.json({ type: 'file', encoding: 'base64', sha: `blob-${revision}`, content: Buffer.from(content).toString('base64') });
    }
    assert.equal(method, 'PUT');
    const body = JSON.parse(String(init?.body));
    assert.equal(body.branch, 'main');
    if (content !== undefined) assert.equal(body.sha, `blob-${revision}`);
    else assert.equal(body.sha, undefined);
    content = Buffer.from(body.content, 'base64').toString('utf8');
    revision++;
    return Response.json({ commit: { sha: `commit-${revision}` } }, { status: 201 });
  };
  return {
    request,
    requests,
    get content() { return content; },
    get writes() { return revision; },
    fail(status: number) { failure = status; },
  };
}

test('rejects prereleases, unsafe versions, invalid checksums, and mismatched URLs', () => {
  for (const version of ['0.9.8-beta.1', 'v0.9.8', '01.0.0', '0.9.8; echo invalid']) {
    assert.throws(() => renderCask(release(version)), /stable/);
  }
  assert.throws(() => renderCask(release('0.9.8', 'invalid')), /SHA-256/);
  assert.throws(() => renderCask({ ...release(), downloadUrl: release('0.9.8').downloadUrl }), /URL/);
});

test('bootstraps an empty tap and verifies the generated cask', async () => {
  const api = tap();
  assert.equal(await prepareHomebrew(release(), 'test-token', api.request), 'created');
  await finalizeHomebrew(release(), 'test-token', api.request);
  assert.equal(api.writes, 1);
  assert.match(api.content!, /depends_on arch: :arm64/);
  assert.match(api.content!, /depends_on macos: :ventura/);
  assert.match(api.content!, /app "AgentBar\.app"/);
});

test('an existing older cask is passed to the standard bump Action', async () => {
  const previous = renderCask(release());
  const api = tap(previous);
  assert.equal(await prepareHomebrew(release('0.10.0'), 'test-token', api.request), 'update');
  assert.equal(api.content, previous);
  assert.equal(api.writes, 0);
});

test('an identical release produces no additional commits', async () => {
  const api = tap(renderCask(release()));
  assert.equal(await prepareHomebrew(release(), 'test-token', api.request), 'unchanged');
  await finalizeHomebrew(release(), 'test-token', api.request);
  assert.equal(api.writes, 0);
});

test('an older release cannot downgrade the tap', async () => {
  const api = tap(renderCask(release('0.10.0')));
  assert.equal(await prepareHomebrew(release('0.9.9'), 'test-token', api.request), 'newer-version');
  assert.equal(api.writes, 0);
});

test('a different DMG cannot replace an already published version', async () => {
  const api = tap(renderCask(release()));
  await assert.rejects(() => prepareHomebrew(release('0.9.7', 'b'.repeat(64)), 'test-token', api.request), /different DMG checksum/);
  assert.equal(api.writes, 0);
});

test('finalization rejects a failed or incomplete bump', async () => {
  const api = tap(renderCask(release()));
  await assert.rejects(() => finalizeHomebrew(release('0.9.8'), 'test-token', api.request), /does not match/);
  assert.equal(api.writes, 0);
});

test('finalization propagates upstream packaging changes and verifies the result', async () => {
  const api = tap(renderCask(release()).replace('macos: :ventura', 'macos: :monterey'));
  await finalizeHomebrew(release(), 'test-token', api.request);
  assert.equal(api.content, renderCask(release()));
  assert.equal(api.writes, 1);
});

test('missing credentials and API failures fail publication', async () => {
  const api = tap();
  await assert.rejects(() => prepareHomebrew(release(), '', api.request), /token is required/);
  api.fail(403);
  await assert.rejects(() => prepareHomebrew(release(), 'test-token', api.request), /HTTP 403/);
  assert.equal(api.writes, 0);
});
