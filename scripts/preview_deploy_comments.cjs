const statusMarker = '<!-- preview-deploy-status -->';
const previewMarker = '<!-- Sticky Pull Request Commentpreview-build -->';
const noPreviewCommentUrl = '__NO_PREVIEW_COMMENT__';

const readMeta = (body, key) => body.match(new RegExp(`<!-- ${key}:(.*?) -->`))?.[1] ?? '';
const isTrustedWorkflowComment = (comment) =>
  comment.user?.login === 'github-actions[bot]' && comment.user?.type === 'Bot';

const findStatusComment = (comments, requestKey) => comments.findLast((comment) =>
  isTrustedWorkflowComment(comment) && comment.body?.includes(statusMarker) &&
  readMeta(comment.body, 'preview-deploy-request-key') === requestKey);

const findPreviewComment = (comments, sourceSha = '') => comments.findLast((comment) =>
  isTrustedWorkflowComment(comment) && comment.body?.includes(previewMarker) &&
  (!sourceSha || readMeta(comment.body, 'preview-build-source-sha') === sourceSha));

function resolveRequestContext({comments, inputs, runId, actor, sourceSha, fallbackSha = ''}) {
  const requestCommentIdInput = (inputs['request-comment-id'] ?? '').trim();
  const requestKey = requestCommentIdInput ? `comment-${requestCommentIdInput}` : `workflow-${runId}`;
  const existingBody = findStatusComment(comments, requestKey)?.body ?? '';
  const requestedBy = inputs['request-comment-user'] ||
    readMeta(existingBody, 'preview-deploy-requested-by') || actor;
  const requestedAt = inputs['request-comment-at'] || readMeta(existingBody, 'preview-deploy-requested-at');
  const requestCommentId = requestCommentIdInput ||
    readMeta(existingBody, 'preview-deploy-last-command-comment-id');
  const requestCommentUrl = inputs['request-comment-url'] ||
    readMeta(existingBody, 'preview-deploy-request-comment-url');
  const fallbackUrl = inputs['request-preview-comment-url'] === noPreviewCommentUrl ? '' :
    inputs['request-preview-comment-url'] || readMeta(existingBody, 'preview-deploy-preview-comment-url');
  const deploySha = sourceSha || readMeta(existingBody, 'preview-deploy-source-sha') || fallbackSha;
  const previewCommentUrl = findPreviewComment(comments, deploySha)?.html_url ?? fallbackUrl;
  return {requestKey, requestedBy, requestedAt, requestCommentId, requestCommentUrl,
    deploySha, previewCommentUrl};
}

async function upsertStatusComment({github, owner, repo, issueNumber, comments, body, requestKey}) {
  const existing = findStatusComment(comments, requestKey);
  if (existing) {
    await github.rest.issues.updateComment({owner, repo, comment_id: existing.id, body});
    return existing.id;
  }
  const {data} = await github.rest.issues.createComment({owner, repo, issue_number: issueNumber, body});
  return data.id;
}

// The one producer of the status table and of the `<!-- preview-deploy-*: -->`
// trailer that readMeta parses back. The request rows come from the same
// metadata, so the visible table and the trailer cannot disagree.
function renderStatusComment({status, workflow, meta, buildDisplay = '', buildNumber = '',
  rows = [], notes = []}) {
  const via = meta['last-command-comment-id'] ? '`/deploy` comment' : 'workflow dispatch';
  return [
    '## 🚀 Preview Deploy',
    '| | Details |',
    '|---|---|',
    `| **Status** | ${status} |`,
    `| **Requested by** | @${meta['requested-by']} via ${via} |`,
    meta['source-sha'] && `| **Preview SHA** | \`${meta['source-sha']}\` |`,
    buildDisplay && `| **Version** | \`${buildDisplay}\` |`,
    buildNumber && `| **Build** | \`${buildNumber}\` |`,
    ...rows,
    meta['request-comment-url'] &&
      `| **Request** | [View /deploy comment](${meta['request-comment-url']}) |`,
    meta['preview-comment-url'] &&
      `| **Preview Comment** | [View preview artifacts](${meta['preview-comment-url']}) |`,
    meta['requested-at'] && `| **Requested at** | ${meta['requested-at']} |`,
    `| **Workflow** | ${workflow} |`,
    ...notes,
    statusMarker,
    ...Object.entries(meta).map(([key, value]) => `<!-- preview-deploy-${key}:${value ?? ''} -->`),
  ].filter(Boolean).join('\n');
}

// Trailer of a deploy run's status comment: the request it serves plus the
// finalized version, so a later /deploy can supersede it.
const deployRunMeta = ({request, state, runUrl, version}) => ({
  state,
  'last-command-comment-id': request.requestCommentId,
  'request-key': request.requestKey,
  'requested-by': request.requestedBy,
  'requested-at': request.requestedAt,
  'request-comment-url': request.requestCommentUrl,
  'preview-comment-url': request.previewCommentUrl,
  'workflow-url': runUrl,
  'source-sha': request.deploySha,
  'build-name': version['build-name'],
  'build-codename': version['build-codename'],
  'build-number': version['build-number'],
  'requested-build-number': version['requested-build-number'],
  'rebuild-required': version['rebuild-required'],
});

const managedReactions = new Set(['eyes', 'rocket', '-1']);

// Leaves `target` (or nothing) as the bot's only managed reaction on a comment.
async function syncManagedReactions({github, owner, repo, commentId, target = ''}) {
  const id = Number(commentId);
  if (!Number.isInteger(id) || id <= 0) return;
  const route = '/repos/{owner}/{repo}/issues/comments/{comment_id}/reactions';
  const headers = {accept: 'application/vnd.github+json'};
  const reactions = await github.paginate(`GET ${route}`,
    {owner, repo, comment_id: id, per_page: 100, headers});
  const mine = reactions.filter((reaction) => managedReactions.has(reaction.content) &&
    reaction.user?.login === 'github-actions[bot]');
  for (const reaction of mine.filter((reaction) => reaction.content !== target)) {
    await github.request(`DELETE ${route}/{reaction_id}`,
      {owner, repo, comment_id: id, reaction_id: reaction.id, headers});
  }
  if (target && !mine.some((reaction) => reaction.content === target)) {
    await github.request(`POST ${route}`, {owner, repo, comment_id: id, content: target, headers});
  }
}

module.exports = {statusMarker, noPreviewCommentUrl, readMeta, isTrustedWorkflowComment,
  findStatusComment, findPreviewComment, resolveRequestContext, upsertStatusComment,
  renderStatusComment, deployRunMeta, syncManagedReactions};
