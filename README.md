# Repository Launcher

A simple desktop launcher for repositories in `~/GitHub`. Each owner gets a column with its GitHub display name and logo above an alphabetical vertical list of repositories. Columns scroll horizontally when needed, and each repository list scrolls independently. Click a repository to open a separate VS Code window.

Public organization and personal owner profiles come from GitHub. Names and logos are cached together for seven days in `~/Library/Caches/studio.repository-launcher/owners`. Fresh cache entries avoid network requests; expired entries refresh automatically when the app opens or becomes active. Previously cached profiles remain available offline. Owners without a GitHub display name fall back to their login.

Repository discovery also refreshes when the app becomes active. It checks `.git` directories and worktree marker files without reading repository contents or credentials.

Build and install with `zsh build-app.sh`. The default destination is `~/Applications/Repository Launcher.app`; an optional first argument changes it. Requires macOS 14 or later, Swift command-line tools, and Visual Studio Code in `/Applications` or `~/Applications`.

Generated app binaries and cached profiles stay outside this checkout.
