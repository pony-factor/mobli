# Repository Launcher

A native macOS launcher for local repositories in `~/GitHub`. Owner folders become groups, with searchable repository cards, persistent favorites, and recently opened projects first within each group. It follows the owner grouping and pinning approach of the ChatGPT repository extension; favorites are stored separately for this app.

Click a repository to open it with VS Code’s `--new-window` option. Existing windows stay open. The sidebar filters owners or favorites, and the folder picker supports another checkout root. Refresh with Command-R after adding repositories. Discovery checks for `.git` directories or worktree marker files without reading repository contents or credentials.

Build and install with `zsh build-app.sh`. The default destination is `~/Applications/Repository Launcher.app`; an optional first argument changes it. Requires macOS 14 or later, Swift command-line tools, and Visual Studio Code in `/Applications` or `~/Applications`.

Source lives in this repository; generated app binaries and app preferences stay outside the checkout.
