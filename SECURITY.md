# Security policy

## Reporting a vulnerability

Please **do not** open a public issue. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/alozdev/lindowin/security/advisories/new).

Include what you found, how to reproduce it and the impact you expect. You will get an answer within 7 days.

## Supported versions

Only the latest release gets fixes. Updating is the same as installing: run the installer again.

## Scope

In scope: the installer, the pipe relay, the port sync service and the administrator setup in this repository.

Out of scope: Docker Engine, the Docker CLI, WSL and Ubuntu themselves. Report those to their projects.
Note that anyone who can run `docker` effectively has root inside the WSL distro, by design (same as Docker Desktop).
