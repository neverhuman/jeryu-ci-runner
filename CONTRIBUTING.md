# Contributing

Outside pull requests are welcome on GitHub.

## How review works

The GitHub repository is a read-only mirror. The forge is where pull requests
are reviewed and merged. When your change is merged there, the GitHub pull
request is closed with a link to the merged change.

Until the importer is live, pull requests are read but not merged yet. Opening
one is still useful: it will be picked up once the importer is running.

## Tests and fixtures

Tests and fixtures must use invented data (for example `acme`, `globex` and
`*.example` names). Never include real hosts, accounts, credentials or paths.

## Running the gate locally

Run the repository's gate before opening a pull request:

```sh
JERYU_SPLIT_FULL_CHECK=1 ./ops/ci/check.sh
```

## Security issues

Do not report vulnerabilities in issues or pull requests. See `SECURITY.md`.
