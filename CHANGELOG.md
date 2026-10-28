# Changelog

## Unreleased
- Inbox: "People only" (on by default) hides threads that only moved because of a bot, CI or your own activity. Mentions and review requests always show; other rows name the person and the time they commented.
- Inbox: days with more than 15 items open the rest in a submenu instead of sending you to github.com.
- Inbox: GitHub notifications that involve you (mentions, review requests, comments, assignments, your threads) from the last 7 days, grouped by day (Today, Yesterday, then weekday), newest first. Unread rows are marked ●, mentions @. Clicking a row opens it and marks it read; "Mentions only" filter and "Mark all as read". Toggle it under Sections to display.
- Desktop notification when someone @mentions you or your team.

## 1.0.0

First public release.

- Graphite-style PR tray in the macOS menu bar: needs your review, returned to you, approved, waiting for reviewers, drafts, merging, waiting for author.
- Sign in with GitHub (OAuth device flow); token stored in the macOS Keychain. Falls back to `gh auth token` when signed out.
- Pinned repos setting: pinned repos sort first in every section.
- Notifications for review requests, changes requested, approvals, failing CI, merged and closed PRs.
- Global shortcut (Option-Command-G) to open the tray, launch at login, configurable polling.
- Update check against GitHub Releases.
- Demo mode (`-demo`) with fake data for screenshots.
