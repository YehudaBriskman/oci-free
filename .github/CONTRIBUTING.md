# Contributing

Thanks for looking. This is a personal project: the infrastructure one person
runs on an Oracle Cloud Always Free tenancy. That shapes how contributions work
here.

**Issues welcome, pull requests by invitation.**

## Issues

Open one for:

- a bug: a manifest that does not apply, a script that misbehaves, a check
  that passes when it should not;
- an idea, or a question about why something is set up the way it is;
- a docs page that is wrong or unclear.

Use the templates under **New issue**.

## Pull requests

Please do not open a pull request unprompted. Open an issue first. If a change
makes sense and you would like to write it, say so in the issue, and if the
answer is yes you will be asked for a PR there. An unrequested PR may be closed
without review: every change here runs on a live cluster that one person looks
after.

When you have been asked for one:

- keep it to one subject;
- run the checks that apply locally (see "CI and tests" in the README:
  `tests/manifests.sh`, `tests/helm.sh`, `tests/scripts.sh`, `tofu validate`);
- never include a credential, an address or a hostname of a real deployment;
- fill in the pull request template.

Every pull request has to pass the required `CI gate` check.

## Licence of contributions

This repository is MIT-licensed ([LICENSE](../LICENSE)). By contributing you
agree that your contribution is licensed under the MIT License.

## Conduct and security

Be decent: see the [Code of Conduct](CODE_OF_CONDUCT.md). Never report a
vulnerability in a public issue: see the [security policy](SECURITY.md).
