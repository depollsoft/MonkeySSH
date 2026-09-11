const {test} = require('node:test');
const assert = require('node:assert/strict');
const {statusMarker, noPreviewCommentUrl, readMeta, findStatusComment,
  findPreviewComment, resolveRequestContext, upsertStatusComment} = require('../../scripts/preview_deploy_comments.cjs');
const meta = (key, value) => `<!-- ${key}:${value} -->`;
const bot = {login: 'github-actions[bot]', type: 'Bot'};
const status = (id, key, user = bot) => ({id, user,
  body: statusMarker + meta('preview-deploy-request-key', key)});
const preview = (id, sha, user = bot) => ({id, user, html_url: `preview/${id}`,
  body: '<!-- Sticky Pull Request Commentpreview-build -->' + meta('preview-build-source-sha', sha)});

test('selectors require both trusted login and Bot type, and select the latest matching request/SHA', () => {
  const comments = [status(1, 'comment-1'), status(2, 'comment-1'), status(3, 'comment-2')];
  const previews = [preview(1, 'old'), preview(2, 'old'), preview(3, 'new')];
  for (const user of [{login: 'human', type: 'User'}, {login: 'github-actions[bot]', type: 'User'},
    {login: 'other[bot]', type: 'Bot'}, undefined]) {
    const forged = {...status(4, 'comment-1'), user};
    assert.equal(findStatusComment([...comments, forged], 'comment-1').id, 2);
    assert.equal(findStatusComment([forged], 'comment-1'), undefined);
    assert.equal(findPreviewComment([...previews, {...preview(4, 'old'), user}], 'old').id, 2);
    assert.equal(findPreviewComment([{...preview(4, 'old'), user}]), undefined);
  }
  assert.equal(findStatusComment(comments, 'comment-2').id, 3);
  assert.equal(findStatusComment(comments, 'missing'), undefined);
  assert.equal(findStatusComment([], 'comment-1'), undefined);
  assert.equal(findPreviewComment(previews).id, 3);
  assert.equal(findPreviewComment(previews, 'missing'), undefined);
  assert.equal(findPreviewComment([]), undefined);
  assert.deepEqual(comments.map(c => c.id), [1, 2, 3]);
  assert.equal(readMeta('', 'absent'), '');
});

test('request context preserves input, stored metadata, actor, source SHA and URL fallbacks', () => {
  const stored = status(1, 'comment-7');
  for (const [key, value] of Object.entries({'requested-by': 'saved-user', 'requested-at': 'saved-at',
    'last-command-comment-id': '7', 'request-comment-url': 'saved-request',
    'preview-comment-url': 'saved-preview', 'source-sha': 'saved-sha'})) {
    stored.body += meta(`preview-deploy-${key}`, value);
  }
  const base = {comments: [stored], inputs: {'request-comment-id': ' 7 '}, runId: 99, actor: 'actor'};
  assert.deepEqual(resolveRequestContext(base), {requestKey: 'comment-7', requestedBy: 'saved-user',
    requestedAt: 'saved-at', requestCommentId: '7', requestCommentUrl: 'saved-request',
    deploySha: 'saved-sha', previewCommentUrl: 'saved-preview'});
  const supplied = {...base, sourceSha: 'input-sha', fallbackSha: 'last-sha', inputs: {...base.inputs,
    'request-comment-user': 'input-user', 'request-comment-at': 'input-at',
    'request-comment-url': 'input-request', 'request-preview-comment-url': 'input-preview'}};
  assert.deepEqual(resolveRequestContext(supplied), {requestKey: 'comment-7', requestedBy: 'input-user',
    requestedAt: 'input-at', requestCommentId: '7', requestCommentUrl: 'input-request',
    deploySha: 'input-sha', previewCommentUrl: 'input-preview'});
  assert.equal(resolveRequestContext({...base, fallbackSha: 'last-sha'}).deploySha, 'saved-sha');
  assert.deepEqual(resolveRequestContext({...base, comments: [], inputs: {}, fallbackSha: 'last-sha'}),
    {requestKey: 'workflow-99', requestedBy: 'actor', requestedAt: '', requestCommentId: '',
      requestCommentUrl: '', deploySha: 'last-sha', previewCommentUrl: ''});
  const suppressed = {...base, inputs: {...base.inputs, 'request-preview-comment-url': noPreviewCommentUrl}};
  assert.equal(resolveRequestContext(suppressed).previewCommentUrl, '');
  assert.equal(resolveRequestContext({...suppressed, comments: [stored, preview(2, 'saved-sha'),
    preview(3, 'new-sha')]}).previewCommentUrl, 'preview/2');
});

test('upsert updates only a trusted matching status and otherwise creates a comment', async () => {
  const calls = [];
  const github = {rest: {issues: {updateComment: async args => calls.push(['update', args]),
    createComment: async args => { calls.push(['create', args]); return {data: {id: 10}}; }}}};
  const forged = status(9, 'comment-1', {login: 'human', type: 'User'});
  const args = {github, owner: 'owner', repo: 'repo', issueNumber: 4, body: 'new body', requestKey: 'comment-1'};
  assert.equal(await upsertStatusComment({...args, comments: [status(1, 'comment-1'), forged]}), 1);
  for (const comments of [[], [forged], [status(2, 'comment-2'), forged]]) {
    assert.equal(await upsertStatusComment({...args, comments}), 10);
  }
  assert.deepEqual(calls, [['update', {owner: 'owner', repo: 'repo', comment_id: 1, body: 'new body'}],
    ...Array(3).fill(['create', {owner: 'owner', repo: 'repo', issue_number: 4, body: 'new body'}])]);
});

test('finishing a second deployment leaves the first request status unchanged', async () => {
  const comments = [status(1, 'comment-1'), status(2, 'comment-2')];
  const original = comments[0].body;
  const github = {rest: {issues: {updateComment: async ({comment_id, body}) => {
    comments.find(comment => comment.id === comment_id).body = body;
  }}}};
  const request = resolveRequestContext({comments, inputs: {'request-comment-id': '2'},
    runId: 99, actor: 'requester'});
  const body = status(2, 'comment-2').body + '\nAndroid: success\niOS: failure';
  assert.equal(await upsertStatusComment({github, owner: 'owner', repo: 'repo',
    issueNumber: 4, comments, body, requestKey: request.requestKey}), 2);
  assert.equal(comments[0].body, original);
  assert.equal(comments[1].body, body);
});
