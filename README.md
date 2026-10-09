# GitHub Pulse (grivera.github)

Your GitHub in the Omarchy bar. It shows your contribution heatmap and streak, traffic for every repo (kept day by day past GitHub's 14-day window), stars, forks and followers, your review queue, your PRs with their checks, and your GitHub notifications. If you publish Omarchy plugins, it also shows the marketplace numbers for each of them: page views, install copies and hearts. A desktop alert arrives when something happens.

## Install

```
omarchy plugin add https://github.com/grivera82/omarchy-github.git --enable
```

It signs in through the GitHub CLI, so if `gh auth status` shows you're logged in, you're done. Otherwise, use one of these:

- `gh auth login` (recommended; the default token covers everything, notifications included)
- a token in `$GH_TOKEN` or `$GITHUB_TOKEN`
- a token in `~/.config/grivera-github/token` (`chmod 600` it). A classic token needs the `repo` scope for private repos and traffic. Fine-grained tokens work too, but they can't read notifications.

The token stays in the daemon's memory. It isn't written to disk or passed on a command line.

To update or uninstall:

```
omarchy plugin update grivera.github
omarchy plugin remove grivera.github
rm -rf ~/.cache/grivera-github ~/.local/state/grivera-github   # optional: history and settings
```

## What it does

- **In the bar:** the GitHub mark. By default, `+3` appears next to it when something new happens (stars, forks, followers, hearts, new cloners, review requests and so on), and clears when you open the panel. Settings can show your streak, today's contributions, unique cloners, marketplace installs or your inbox count instead. A red dot means someone is waiting on your review or a check failed on your PR. Left-click opens the panel. Right-click opens GitHub (your notifications, review requests or profile). Middle-click refreshes.
- **Since you last looked:** each time you open the panel, it fetches fresh numbers and shows what changed since you last closed it: new cloners and visitors, install copies, hearts, stars, forks, followers, contributions and events, with "+N new" badges on the repos and plugins that moved. Click a chip to jump to the details.
- **Overview:** tiles for contributions today, your streak, unique cloners and visitors over 14 days, stars, followers, marketplace installs and hearts. Below them are the contribution calendar (hover a day for its count) and a 30-day traffic chart you can switch between cloners, clones, visitors and views. Then your top repos and your year in numbers: commits, PRs, issues, reviews, best day and active days. The ↻ button in the header refreshes everything now. It spins until the fetch finishes, and its tooltip shows when the data was last updated.
- **Repos:** every repo you own, sorted by traffic, stars, last push or name, with language, CI state, a 14-day sparkline, and stars, forks, cloners and visitors. Click a repo for its daily chart, all-time totals since tracking began, referrers, top pages and links.
- **Activity:** a feed of new stars, forks, followers and unfollows, issues and PRs other people open on your repos, review requests, check results, approvals and merges on your PRs, releases, marketplace hearts and install copies, and new cloners per repo per day. Filters: All, Stars & people, Installs, Code.
- **Inbox:** review requests, your open PRs (draft, approved, changes requested, merge conflict and CI badges), issues and PRs assigned to you, and unread GitHub notifications. Click an item to open it. You can mark notifications read one at a time or all at once.
- **Plugins:** appears when the [Omarchy plugin marketplace](https://omarchyplugins.com) lists a repo you own. Each listing shows its views, install-command copies and hearts with weekly changes, a daily-copies sparkline, rank by installs, and verification state ("update unverified" when your latest commit hasn't been verified yet). Unique cloners from GitHub traffic count real installs, since `omarchy plugin add` clones the repo.
- **Alerts:** stars, followers, forks, new issues and PRs, review requests, CI results, approvals and merges, and marketplace hearts are on by default. Install copies, new cloners, every GitHub notification and an evening streak reminder are off by default. Clicking an alert opens the related page. Bursts of the same kind are grouped into one alert.

Keys while the panel is open: `1`–`6` tabs, `←`/`→` change the metric, sort or filter, `j`/`k` scroll, `o` opens your profile, `m` marks notifications read, `r` refreshes, `?` explains every number on the Overview and Plugins tabs, `Esc` closes. Hovering a number shows the same explanation.

## CLI

```
~/.config/omarchy/plugins/grivera.github/bin/github status          # summary from the last snapshot
~/.config/omarchy/plugins/grivera.github/bin/github status --json
~/.config/omarchy/plugins/grivera.github/bin/github open            # your profile in the browser
omarchy-shell grivera.github toggle                                  # open/close the panel (for a keybinding)
```

## Status for scripts and voice assistants

`omarchy-shell grivera.github status` prints a JSON summary: contributions and streak, traffic, top repos by cloners, your review queue and PRs, notifications, recent activity and marketplace numbers. Private repos are counted but never named, and their titles are left out. Voice assistants such as [Jarvis](https://github.com/grivera82/omarchy-jarvis) use it to answer questions. It only reads, and works while the widget is in the bar.

## API use

GraphQL for your profile, repos and contributions (every 10 minutes, every 3 while the panel is open), plus the review/PR search (every 5 minutes). REST covers notifications (at GitHub's poll interval, with conditional requests that don't count against your limit) and traffic (hourly, 2–4 requests per repo). Stargazers, forks, followers and new issues are fetched only when a count changes. Marketplace stats refresh every 30 minutes, and the 13 MB catalog every 6 hours. A typical hour uses a few hundred of your 5,000 requests.

## Files

- `~/.local/state/grivera-github/`: settings, activity feed, daily history (traffic, marketplace, totals) and the baselines used to detect what changed
- `~/.cache/grivera-github/`: the last fetched data and your avatar

Both are created with owner-only permissions.

## License

MIT
