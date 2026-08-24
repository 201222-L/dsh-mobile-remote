# Agent instructions

## Git remotes

- `origin` is the user's GitHub fork: `git@github.com:marktrue-ahu/dsh-mobile-remote.git`.
- `source` is the original upstream repository: `git@github.com:201222-L/dsh-mobile-remote.git`.
- Fetch and compare upstream changes from `source`.
- Push the user's branches and tags to `origin`.
- Treat `source` as read-only unless the user explicitly authorizes a push to the original project.
- Before any pull, rebase, merge, push, or tag operation, verify the target remote and current branch.
