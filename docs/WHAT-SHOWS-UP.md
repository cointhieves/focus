# What shows up in Focus, and why

Focus shows what's waiting on **you**: things you own, things aimed at you personally,
and things aimed at your team that nobody on the team has picked up yet. Everything else
stays out, even if Slack or Jira notifies you about it.

This page is the reference for every rule. If you change what pops or clears an item,
update this page in the same commit.

- [Jira](#jira)
- [Slack](#slack)
- [Tasks](#tasks)
- [Timing](#timing)
- [What you can do with an item](#what-you-can-do-with-an-item)
- [FAQ](#faq)
- [How to check what's going on](#how-to-check-whats-going-on)

## Jira

"A person" below means a real Atlassian user. Integration and app accounts never count,
and neither does anyone on **Settings → Jira → Advanced → Ignore comments from**.

| Situation | Shows? | Pops (jumps to the top) when | Clears when |
|---|---|---|---|
| Ticket **assigned to you**, In Progress, in an **open sprint** | Yes (**Sprint tickets**) | Any comment from a person after your latest comment. No @mention needed. | You comment. It comes back on its own at the **start of your next workday** (Friday → Monday), or sooner once your comment is older than "green until" in business hours. |
| Same, and you've **never commented** | Yes, straight away | A person comments | You comment |
| Ticket you're **@mentioned** on, not in your sprint | Yes (**Mentions**) | Someone @mentions you after your latest comment | You comment, or the ticket is Done |
| Ticket **you reported**, in **another team's project** (a support queue, say) | Yes (**Tickets I reported**) | A person comments after you **without tagging someone else**, or @mentions you | You comment, or the ticket is Done |
| Ticket **you reported**, in **your team's project**, someone else is working it | Only if you're @mentioned | Someone @mentions you | You comment, or the ticket is Done |
| A comment that **tags someone else** on a ticket you reported | No | — | — |
| A ticket you only **watch** | No | — | — |
| Your sprint ticket moves to **Done** | Plays **CLOSED**, then leaves | — | — |
| Your sprint ticket leaves the sprint, goes back to To Do, or is reassigned | Stays, marked **REMOVED** | — | You dismiss it |

**Your team's projects** are the projects your own sprint tickets come from. Focus learns
them automatically and forgets one that hasn't appeared in your sprint for 30 days.
Nothing is configured and no project names are built in, so this works the same for
every user.

**Mentions** are found by searching the last 3 days (30 days the first time Focus runs).
A mention already in the queue stays until it's answered, however old it gets.

**Ignore comments from** takes an email address, or a name if only one person matches.
Use it for automation that posts as a regular user.

## Slack

"A person" below means a real user. Bots and apps never count, except in bot-alert
channels (see below).

| Situation | Shows? | Pops when | Clears when |
|---|---|---|---|
| **DM** or **group DM** with a message from someone else newer than your last response | Yes (**DMs**, **Group DMs**) | The first unanswered message arrives | You reply, or react to a message in it |
| **Thread** you've posted in during the last 7 days | Yes (**Threads**) | A person replies after your last response | You reply in the thread, or react to a reply |
| **Personal @mention** of you in a channel | Yes (**Mentions**) | The mention arrives | You reply after it (in the channel or its thread), or react to it |
| **Personal @mention** of you inside a thread | Yes, as the whole thread (**Threads**) | Any later reply from a person | You reply in the thread, or react |
| **Your group** is tagged (@your-team), you're not tagged personally | Yes, that one message only (**Mentions**): "Ann tagged @your-team in #help" | The tag arrives | **A member of that group** (you included) replies in its thread after the tag, or you react to it. Replies from people outside the group don't clear it. |
| A **different group** is tagged, one you're not in | No | — | — |
| **@here** / **@channel** | No | — | — |
| **Bot** message in a channel on **Settings → Slack → Advanced → Bot alerts from**, tagging you or your group | Yes, one item per alert | The alert arrives | You reply in the alert's thread, or react to it |
| **Bot or app** messages anywhere else (including app DMs like calendar notifications) | No | — | — |

A group tag no longer pulls you into the whole thread: after the tag, other replies don't
pop anything unless you're personally @mentioned or have posted there yourself.

**Your groups** are the Slack user groups that list you as a member, refreshed hourly.
Focus checks each message really tags you or one of your groups, because Slack's search
also returns messages tagging other groups.

A **reaction** counts as responding. Where you stand in a conversation is the later of
your last message and the newest message you reacted to.

## Tasks

Tasks are items you add yourself. "by 5pm", "by Friday 3pm" or "in 30 minutes" in the
text sets a deadline; a task that hits its deadline jumps to the top. Tasks stay until
you mark them **Done**.

## Timing

- **Business hours** come from Settings (default 9 AM to 5 PM, Monday to Friday). Ages,
  colours and "next workday" all count only business hours.
- **Colours:** Jira is green for 8 business hours, then amber, red at 16. Slack is green
  for 1 business hour, then amber, red at 2. All four are settings.
- **Sync:** Jira every 15 seconds, Slack every 30 seconds.
- **Order:** new or popped items first (deadlines, then Slack, then Jira), each
  oldest-first; then everything else by how long it has waited; then skipped items;
  then boomeranged items.
- Turning a source or checkbox **off hides** its items; it doesn't delete them. Turning it
  back on restores them without popping everything again.

## What you can do with an item

| Action | What it does |
|---|---|
| **Click** | Opens it. The panel hides while you reply and comes back after 5 minutes (a setting) or when you switch apps. |
| **Skip** | Sends it to the back of the line. |
| **Dismiss** | Hides it until something new happens on it. |
| **Boomerang** | Snoozes it for 2 business hours (a setting), or until something new happens. It returns to where it was. |
| **Done** | Tasks only: deletes the task. |

## FAQ

**Someone commented on my ticket without tagging me. Will I see it?**
Yes if the ticket is assigned to you in your sprint. Yes if you reported it in another
team's queue and the comment doesn't tag someone else. No if you reported it in your own
team's project and someone else is working it. [Jira rules](#jira)

**I created a ticket in my team's project and a teammate is working it. What alerts me?**
Only an @mention of you. [Jira rules](#jira)

**I closed a ticket but it's still in Focus.**
It should play CLOSED within one sync (about 15 seconds). If it doesn't, Jira's search may
still be catching up; the next sync fixes it.

**I answered a ticket this morning. When does it come back if nobody replies?**
At the start of your next workday, or sooner once 8 business hours have passed since your
comment.

**Why did a #help channel thread show up?**
You posted in it, you were @mentioned in it, or one of your groups was tagged. For a group
tag, only that message shows, and it clears once someone in the group replies.

**Someone tagged my team and a teammate answered. Why is it gone?**
A group tag is done once any member of that group replies in the thread after it.

**The asker added more detail after tagging my team, but nobody from my team answered.**
It stays. Only replies from group members clear a group tag.

**Does an emoji reaction count as replying?**
Yes, on Slack.

**Why don't calendar or other app messages show up?**
Bot and app messages are filtered out, apart from alerts in the channels you list under
**Bot alerts from**.

**Why are notifications from Jira or Slack not all in Focus?**
Jira and Slack notify you about everything you're involved in; Focus shows only what's
waiting on you. For example, being the reporter of a ticket where others are talking to
each other isn't waiting on you.

## How to check what's going on

- The **status line** at the bottom of each section in Settings shows the last sync and
  how many items need you. Red means something needs fixing.
- `focus list --json` prints the queue with each item's source and details.
- Settings → **Try it** runs each behaviour on demo items.
