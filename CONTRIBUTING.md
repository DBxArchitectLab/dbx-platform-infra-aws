# Contributing

This repository is the AWS part of [DBX Architect Lab](https://www.youtube.com/@DBxArchitectLab), one live enterprise Databricks platform built
in public. Questions, ideas and fixes are welcome.

## Questions, bugs and ideas

Open an [issue](../../issues). To get a useful answer quickly, include:

- the stack (`metastore`, `<env>-dbxarchitectlab-workspace` or `<env>-dbxarchitectlab-workspace-bootstrap`) and the
  action (`validate`, `plan`, `apply` or `destroy`)
- the error and the log lines around it, with secrets, account and subscription IDs, and IP addresses removed
- what you expected to happen

Questions about a video can also go in the video's YouTube comments.

## Pull requests

1. Fork the repository and create a branch.
2. Keep the change focused, and explain *why* in the pull request description, not only what changed.
3. Before you open it:
   - format the code: `terraform fmt -recursive modules` and `terragrunt hclfmt`
   - describe how you tested it, for example the `plan` output from your own environment (redacted)
   - update `README.md` or `DEPLOYMENT.md` if the change affects how the platform is deployed

Every pull request is reviewed before it is merged. Deployments run only from the maintainer's GitHub environments:
pull requests from forks never deploy anything and never see this repository's secrets.

## Never commit secrets

Credentials belong in GitHub environment secrets or your local environment, never in files: no AWS access keys, Databricks OAuth client secrets,
Terraform state files or `.env` files. If you find a secret in the history, report it privately to the maintainer
instead of opening a public issue.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the same
license as this repository.
