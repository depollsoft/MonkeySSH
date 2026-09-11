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

module.exports = {statusMarker, noPreviewCommentUrl, readMeta, isTrustedWorkflowComment,
  findStatusComment, findPreviewComment, resolveRequestContext, upsertStatusComment};
