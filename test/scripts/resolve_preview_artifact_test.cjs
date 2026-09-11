const test = require('node:test');
const assert = require('node:assert/strict');
const {matchesBuild, resolve} = require('../../scripts/resolve_preview_artifact.cjs');

const identity = {sha: 'a'.repeat(40), buildNumber: '178878449', repository: 'owner/repo'};
const producer = {id: 20, workflow_id: 7, event: 'pull_request', head_sha: identity.sha,
  head_repository: {full_name: identity.repository}, status: 'completed', conclusion: 'success',
  display_title: `iOS preview #811 / ${identity.sha} / 2026-09-07T12:34:56Z`};
const name = `ios-unsigned-private-1.2.3-${identity.buildNumber}-${identity.sha}.ipa`;

function fixture({artifacts = [], runs = [], run = producer, afterWait} = {}) {
  const calls = {waits: 0, lists: 0};
  const actions = {
    getWorkflow: async () => ({data: {id: 7}}),
    listArtifactsForRepo: async () => { calls.lists++; return {data: {artifacts}}; },
    getWorkflowRun: async () => ({data: run}),
    listWorkflowRuns: async () => ({data: {workflow_runs: runs}}),
  };
  const sleep = async (ms) => {
    assert.equal(ms, 20_000);
    calls.waits++;
    if (afterWait) artifacts = afterWait(calls.waits);
  };
  return {calls, options: {github: {rest: {actions}}, owner: 'owner', repo: 'repo',
    sha: identity.sha, buildName: '1.2.3', buildNumber: identity.buildNumber, sleep}};
}
const artifact = {name, expired: false, workflow_run: {id: producer.id}};

test('producer identity includes repository, source SHA, event, and event version', () => {
  assert.equal(matchesBuild(producer, identity), true);
  for (const difference of [{head_sha: 'b'.repeat(40)}, {event: 'push'},
    {head_repository: {full_name: 'fork/repo'}}, {display_title: 'invalid'},
    {display_title: 'iOS preview / 2026-09-07T12:35:56Z'}]) {
    assert.equal(matchesBuild({...producer, ...difference}, identity), false);
  }
});

test('uses a completed exact artifact without waiting', async () => {
  const {options, calls} = fixture({artifacts: [artifact]});
  assert.deepEqual(await resolve(options), {name, runId: '20'});
  assert.equal(calls.waits, 0);
});

test('legacy workflow_run artifact remains usable during migration', async () => {
  const {options} = fixture({artifacts: [artifact], run: {...producer, event: 'workflow_run', head_sha: 'old-main'}});
  assert.deepEqual(await resolve(options), {name, runId: '20'});
});

test('rejects expired, wrong-name, and provenance-free artifacts', async () => {
  for (const difference of [{expired: true}, {name: name + '-old'}, {workflow_run: undefined}]) {
    const {options, calls} = fixture({artifacts: [{...artifact, ...difference}]});
    assert.equal(await resolve(options), null);
    assert.equal(calls.waits, 0);
  }
});

test('rejects wrong workflow, failed runs, forks, and a different commit', async () => {
  for (const difference of [{workflow_id: 8}, {conclusion: 'failure'}, {event: 'push'},
    {head_sha: 'b'.repeat(40)}, {head_repository: {full_name: 'fork/repo'}}]) {
    const {options, calls} = fixture({artifacts: [artifact], run: {...producer, ...difference}});
    assert.equal(await resolve(options), null);
    assert.equal(calls.waits, 0);
  }
});

test('no producer, failed producer, or unrelated active producer falls back immediately', async () => {
  for (const runs of [[], [{...producer, conclusion: 'failure'}],
    [{...producer, status: 'in_progress', display_title: 'iOS preview / 2026-09-07T12:35:56Z'}]]) {
    const {options, calls} = fixture({runs});
    assert.equal(await resolve(options), null);
    assert.equal(calls.waits, 0);
  }
});

test('waits for an exact active producer and reuses the finished artifact', async () => {
  const {options, calls} = fixture({runs: [{...producer, status: 'in_progress'}], afterWait: () => [artifact]});
  assert.deepEqual(await resolve(options), {name, runId: '20'});
  assert.equal(calls.waits, 1);
});

test('even a matching active producer cannot hold deployment indefinitely', async () => {
  const {options, calls} = fixture({runs: [{...producer, status: 'queued'}]});
  assert.equal(await resolve(options), null);
  assert.equal(calls.waits, 6);
  assert.equal(calls.lists, 7);
});

test('API failures are visible instead of silently selecting another artifact', async () => {
  const {options} = fixture();
  options.github.rest.actions.listArtifactsForRepo = async () => { throw new Error('API unavailable'); };
  await assert.rejects(resolve(options), /API unavailable/);
});
