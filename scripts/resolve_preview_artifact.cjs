// Only wait for a live producer of the exact PR-event build we want to reuse.
const ACTIVE = new Set(['queued', 'in_progress', 'requested', 'waiting', 'pending']);

function matchesBuild(run, {sha, buildNumber, repository}) {
  if (run.event !== 'pull_request' || run.head_sha !== sha ||
      run.head_repository?.full_name !== repository) return false;
  const timestamp = run.display_title?.split(' / ').at(-1);
  return String(Math.floor(Date.parse(timestamp) / 1000 / 10)) === String(buildNumber);
}

async function resolve({github, owner, repo, sha, buildName, buildNumber,
  sleep = (ms) => new Promise((done) => setTimeout(done, ms)), maxWaits = 6}) {
  const request = {timeout: 10_000};
  const {data: workflow} = await github.rest.actions.getWorkflow({
    owner, repo, workflow_id: 'preview-ios.yml', request,
  });
  const name = `ios-unsigned-private-${buildName}-${buildNumber}-${sha}.ipa`;
  for (let attempt = 0; attempt <= maxWaits; attempt += 1) {
    const {data: listing} = await github.rest.actions.listArtifactsForRepo({
      owner, repo, name, per_page: 100, request,
    });
    for (const artifact of listing.artifacts) {
      if (artifact.expired || artifact.name !== name || !artifact.workflow_run?.id) continue;
      const {data: run} = await github.rest.actions.getWorkflowRun({
        owner, repo, run_id: artifact.workflow_run.id, request,
      });
      // The old workflow_run producer used the default branch as head_sha;
      // its source-qualified artifact name remains valid during migration.
      const sourceMatches = run.event === 'workflow_run' ||
        (run.event === 'pull_request' && run.head_sha === sha &&
         run.head_repository?.full_name === `${owner}/${repo}`);
      if (run.workflow_id === workflow.id && run.conclusion === 'success' && sourceMatches) {
        return {name, runId: String(run.id)};
      }
    }
    if (attempt === maxWaits) return null;
    const {data: producers} = await github.rest.actions.listWorkflowRuns({
      owner, repo, workflow_id: workflow.id, event: 'pull_request',
      head_sha: sha, per_page: 100, request,
    });
    if (!producers.workflow_runs.some((run) => ACTIVE.has(run.status) &&
        matchesBuild(run, {sha, buildNumber, repository: `${owner}/${repo}`}))) return null;
    await sleep(20_000);
  }
  return null;
}

module.exports = {matchesBuild, resolve};
