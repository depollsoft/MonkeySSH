#!/usr/bin/env python3
"""Export a PR's commit subjects as FLUTTY_PR_COMMITS for preview release notes.

Best effort: on any failure it warns and leaves the variable unset, and the
release notes fall back to the source commit subject.
"""

import json
import os
import sys
import urllib.request
import uuid

MAX_COMMITS = 100


def fetch_commits(repo, pr, token, urlopen=urllib.request.urlopen):
    headers = {'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json'}
    commits = []
    page = 1
    while len(commits) < MAX_COMMITS:
        url = f'https://api.github.com/repos/{repo}/pulls/{pr}/commits?per_page=100&page={page}'
        data = json.loads(urlopen(urllib.request.Request(url, headers=headers)).read())
        commits.extend(data)
        if len(data) < 100:
            break
        page += 1
    return commits[:MAX_COMMITS]


def env_block(commits, delimiter=None):
    """Newest-first `<sha7> <subject>` lines as a GITHUB_ENV heredoc."""
    delimiter = delimiter or f'FLUTTY_EOF_{uuid.uuid4().hex}'
    subjects = [(c['sha'][:7], c['commit']['message'].split('\n')[0]) for c in reversed(commits)]
    lines = [f'{sha} {subject}' for sha, subject in subjects]
    return f'FLUTTY_PR_COMMITS<<{delimiter}\n' + '\n'.join(lines) + f'\n{delimiter}\n'


def main():
    try:
        commits = fetch_commits(os.environ['GITHUB_REPOSITORY'], os.environ['PR_NUMBER'],
                                os.environ['GH_TOKEN'])
        with open(os.environ['GITHUB_ENV'], 'a') as env:
            env.write(env_block(commits))
    except Exception as error:  # pylint: disable=broad-except
        print(f'Warning: failed to fetch PR commits: {error}', file=sys.stderr)


if __name__ == '__main__':
    main()
