# What already exists around Burnbot: market landscape

Research as of 2026-11-18. The interactive version, with filters, every product's sources and the full catalogue, is `market-map.html` in this folder (published privately at https://claude.ai/artifact/58UU5hcDAYTTA7yfLhdqWJ; share it from the page's Share menu). The data behind both is in `products.json`.

## Bottom line

**Burnbot is a robot for Claude Code that lives on your Mac and on a small screen on your desk. We mapped 1,752 products around it. Desk hardware draws the biggest crowds, and none of the 16 desk devices we profiled notices progress the way Burnbot does. But buyers expect DIY prices, and the one breakout campaign won with multi-agent support, voice and approvals.**

What the research says:

Burnbot judges a Claude Code session against the user's own history and spots moments like tests going red to green, which none of the 37 profiled products does. It lags on features many rivals have: more agents, plan limits, sound and approving from the device. Lead with progress, close the cheap gaps, and plug into Anthropic's hardware protocol rather than fight funded hardware.

- The market is crowded and mostly free. The catalogue holds 1,752 names after merging, including 377 more T1 hardware displays, 261 more T1 desktop companions and 371 more usage monitors.
- Burnbot's edge is judging the session, not just showing it. None of the 37 profiled products has personal-baseline levels, red-to-green detection or drift detection at yes.
- Burnbot is behind on common features. It supports one agent on one OS, shows no plan limits, plays no sound, cannot approve from the robot, and its multi-session view is only partial.
- The closest free rival is Clawd on Desk. It is AGPL, has 6,777 stars, covers nearly 30 agents on three OSes, and already does approvals, plan limits, sound and history.
- SlashVibe is the one funded breakout: $143,175 from 639 backers on a $10,000 goal. It is a $169 to $249 multi-agent console due to start shipping in March 2027. Other coding-agent hardware campaigns mostly raised little.
- The biggest threat is the platform. Claude Code already has a usage streak, a heatmap, recaps, Remote Control alerts and status-line limits. Anthropic also publishes a BLE protocol for desk hardware.
- Suggested direction: stay free and local-first, lead with progress instead of burn, add plan limits and quiet sounds, and make the desk screen speak the Hardware Buddy protocol.

## What the next four weeks could look like

If we go ahead, this is roughly what the first four weeks could hold. It isn't a fixed plan: four tracks that can all start on day one and run side by side, with the desk device at the centre. The case for and against, and every option we weighed, are in chapter 8.

**The desk device**

- _Weeks 1 to 2:_ Port the desk screen to two boards people already own: Hardware Buddy's M5StickC Plus (about $30) and Clawdmeter's Waveshare AMOLED ($29.99).
- _Weeks 2 to 3:_ Its button does what 'Go to it' does today: bring the waiting session forward.
- _Weeks 2 to 4:_ Flash it from the Mac app in one click, the way Clawdmeter's tray app does for 28 boards.
- _Weeks 3 to 4:_ Try speaking Hardware Buddy's Bluetooth protocol, to see how far our moments travel on boards that already run it.

**What the robot notices**

- _Week 1:_ A licence and a Homebrew cask, so people can trust the app and install it in one line.
- _Weeks 1 to 2:_ Lead with progress: a cheer when a test goes red to green, a '!' when Claude needs you, a look when you drift. Re-weight the levels so token burn isn't 40% of them.
- _Weeks 2 to 3:_ Plan limits shown in the robot's mood, and quiet sounds that are off by default.
- _Weeks 3 to 4:_ Fix moments that fire at the wrong time, from what the first builders say.

**Showing it**

- _Weeks 1 to 2:_ A build guide with a parts list under $40, and a short clip of the desk robot cheering when a test goes green.
- _Weeks 2 to 4:_ Reach the people who miss /buddy: the Bring Back Buddy issue has 1,197 thumbs-up.
- _Week 3:_ Posts on r/ClaudeCode, r/ClaudeAI and r/esp32, and a Show HN.
- _Weeks 3 to 4:_ Answer the comments, and note which boards people ask for.

**Would anyone pay?**

- _Week 1:_ Open a refundable-deposit list for a ready-made unit. Vibe Buddy takes $5 toward a $49 unit.
- _Weeks 1 to 4:_ Talk to a handful of people who built a Clawdmeter or a Hardware Buddy: what they'd pay, and what's missing.
- _Weeks 2 to 4:_ Cost out a kit (board plus printed case) and a small batch, against what sells today: finished small displays go for $49 to $115.

**Where we'd be after four weeks**

- The desk robot running on two boards people already own, flashed from the app.
- A launch post with its score, and a first read on stars and builds.
- A deposit list with its first numbers, and a rough cost for a kit and a small batch.
- Enough to choose what comes next: stay DIY, a kit, a small batch, or a campaign.

_Not in these four weeks: making hardware, a crowdfunding campaign, a paid app, or a second agent such as Codex. Those wait for the numbers._

**How we'd know it's working**

- Points on the launch post: 306 is the median of the 11 desk-hardware show-and-tell posts we found; 86 is the median of the software ones. Below 86 is a warning sign. (for comparison: Lump 244, Clawdmeter 1,674)
- GitHub stars: Reaching the low hundreds puts us in Clauddy's range. Desk firmware can go much further: Clawdmeter has 2,349. Staying in the tens is a warning sign. (for comparison: Clauddy 125, Clawdmeter 2,349)
- Deposits for a ready-made unit: Compared with backer counts of agent-hardware campaigns: under about 15 they failed or barely funded; CtrlVibe's 59 raised about $10,261; SlashVibe's 639 raised $143,175. (for comparison: AgentDeck 3, V14 13, CtrlVibe 59, SlashVibe 639)
- Do people get the firmware running from the guide, and which boards do they ask for?
- On the desk, do the moments feel right, and do the levels feel like encouragement rather than pressure?
- Do people ask where to buy one ready-made, and at what price?
- Does Anthropic add progress moments to Claude Code or Hardware Buddy, or sell a device of its own?

## Should we enter?

_These are our reflections on the research, not findings. The numbers come from the checked data in this report; the judgments, the four-week outline and the thresholds are suggestions for the team to argue with._

The desk device is the heart of Burnbot; the Mac app is its brain. The app is out (free, version 1.3) and the desk screen already runs on two DIY boards. So the real question is how far to take the device: firmware for boards people already own, a kit, or a device we make and sell. The research says desk hardware gets the most attention, but people expect to build it for $10 to $40, and small hardware campaigns mostly raised little. One spot is empty on every desk device we found: none of them notices progress.

### For

- **We hold the one empty spot.** None of the 37 profiled products has personal-baseline levels, red-to-green or drift detection at yes. Burnbot has all three.
- **People want companions like this and upvote them.** The 25 show-and-tell posts we found have a median score of 99. The top ones are companions: Clawdmeter scored 1,674 and a desk lamp status light 1,637. Clauddy, a free pixel pet much like Burnbot, got 179 points and has 125 GitHub stars.
- **People want a character, not just a meter.** 'Bring Back Buddy', the GitHub issue asking Anthropic to restore Claude Code's removed pet, has 1,197 thumbs-up. Burnbot's robot already reacts to real moments.
- **Waiting and wellbeing is an open lane.** A thread on staying in flow while Claude works got 307 points and 248 comments, and '10x more productive, but mentally exhausted' got 306. No profiled product does pacing. Burnbot already measures drift and the user's usual break.
- **It is cheap to keep going.** The app exists, runs locally with no servers, and the desk screen uses boards of about $30. The main cost is our time.

### Against

- **The platform can flatten us.** Claude Code already has a usage streak, a heatmap, /insights, /recap, Remote Control alerts and status-line limits, at no extra charge on a paid plan. If Anthropic adds progress moments, our edge shrinks overnight.
- **Crowded, free and fast-moving.** 1,752 products after merging. Clawd on Desk is free, AGPL, covers nearly 30 agents, has 6,777 stars and ships every 8 to 12 days. Pixel Agents has 98,492 VS Code installs, and its roadmap mentions scores and game elements.
- **Hard to charge for.** Software companions cost $0 to $19.99 one-time (Vibe Island, Fetch). Limit meters cost $0 to $9 (Usagebar). Notch app launches on Hacker News got 1 to 9 points each.
- **Our edge is copyable.** Any single moment, such as red to green or going round, is a weekend's work for a rival. The defence is calibration quality and restraint, which we have not yet proven with users.
- **Our name and fire point the wrong way.** Burn is 40% of each level and the top level is fire. A post mocking $50,000 burned in 30 days got 317 points and 182 comments; a friends' burn leaderboard got 20.
- **Narrow reach.** Claude Code only, macOS only. Being tied to one agent was the top objection to agent hardware.
- **We have no traction data of our own.** The research has no download, star or retention figures for Burnbot, so we can't yet tell whether anyone keeps it running.

### The device, weighed on its own

The points above weigh Burnbot as a whole. These weigh the desk device by itself, using the 16 desk devices we profiled.

**For a device**

- **Desk hardware gets the most attention.** The 11 desk-hardware show-and-tell posts we found have a median score of 306, against 86 for the 14 software ones. The top two posts are both hardware: Clawdmeter, an ESP32 limit meter (1,674), and a desk lamp status light (1,637).
- **The empty spot is even emptier on the desk.** None of the 16 desk devices has levels against your own history, red-to-green, drift, loop detection or a history view at yes. The only progress on any of them is Hardware Buddy's level-up every 50K tokens, which counts volume, not outcomes.
- **People want a character on the desk.** Anthropic's Hardware Buddy, a desk pet with 18 species, has 2,721 stars and 474 forks. Lump, a desk creature that shows what Claude is doing, got 244 points. 6 of the 16 desk devices have a character.
- **The boards are cheap and already on desks.** Hardware Buddy runs on an M5StickC Plus of about $30; Clawdmeter's board costs $29.99 to $31.99, and its tray app flashes 28 boards. Writing firmware for these reaches people without making anything.
- **We already have it working.** Burnbot's desk screen runs today over USB on two DIY setups (a Seeed XIAO nRF52840 with a 2.4 inch screen, where a double knock dismisses a bubble, and an ESP32 with an UNO TFT shield).

**Against selling one**

- **Buyers expect DIY prices.** On the top hardware posts, commenters assume they can build one for $10 to $40, and mock sold units as 'a flashed M5Stack for 10x the price'.
- **Small hardware campaigns mostly flop.** Token Monitor raised EUR 1,153 of EUR 28,000 and failed. AgentDeck had CA$597 from 3 backers. V14 scraped $2,018 of $2,000 from 13. FreakStudio's Tindie page shows no units sold.
- **The winners have what we lack.** SlashVibe ($143,175 from 639 backers) sells multi-agent support, voice and approvals. Codex Micro sold out in about 12 hours on OpenAI's name. Among the 16 desk devices, 8 take voice and 7 approve from the device; Burnbot's screen does neither.
- **Anthropic sets a free standard.** Hardware Buddy is Anthropic's own open protocol and reference pet for a $30 board, and many DIY devices already build on it. A device that ignores it competes with the platform's default.
- **Ours is narrow today.** Two board setups, USB only, not sold, and not compatible with Hardware Buddy. Being tied to one agent was also the top objection in crowdfunding comments.

### The options

| Option | Call | Why |
|---|---|---|
| Firmware for boards people already own | do now | Meets the $10 to $40 DIY expectation, carries the moments no desk device has, and makes no hardware. Hardware Buddy (2,721 stars) and Clawdmeter (2,349 stars) show how far free firmware travels. |
| Free, open app as the brain | do now | The device needs the app, which is where the moments are worked out. Free is the norm, and a licence and Homebrew build trust. |
| Speak the Hardware Buddy protocol | next | Lets our moments run on the boards Anthropic's protocol already reaches, over Bluetooth, instead of our two USB setups. |
| A refundable-deposit list for a ready-made unit | next | Tests whether anyone will pay before we make anything. Vibe Buddy takes a $5 refundable deposit toward a $49 unit. |
| A kit: board, printed case, one-click flashing | later | Only if builds take off. DIY boards cost about $21 to $70, and a kit sits closest to what commenters expect to pay. |
| A finished device in a small batch | later | Only after the deposit list fills. Finished small displays sell for $49 to $115, but FreakStudio shows no sales and Token Monitor's campaign failed. |
| A crowdfunding campaign | later | Only with numbers behind it. SlashVibe raised $143,175, but on multi-agent support, voice and approvals; AgentDeck had 3 backers and Token Monitor 10. |
| Codex as a second agent | later | Matters more for hardware, since lock-in was the top objection to agent devices, but it puts us head-on with Clawd on Desk and OpenAI's own pets. Only once the Claude core is sharp. |
| Paid Mac app, $9 to $20 one-time | later | Only after users show they value the moments. Vibe Island and Fetch show $19.99 one-time can work for a Mac companion. |
| Keep it a side project | fallback | Costs nothing, but the empty spot won't stay empty for long. |

### Keep going if

- The launch post beats 306 points, the median of the desk-hardware show-and-tell posts we found (Lump got 244, Clawdmeter 1,674).
- Stars reach the low hundreds, in Clauddy's range (125).
- People build it from the guide and ask for more boards, or ask where to buy one.
- The deposit list passes about 59, CtrlVibe's backer count.

### Stop or shrink if

- The post scores under 86, the median of the software show-and-tell posts, and stars stay in the tens.
- Fewer than about 15 deposits, where small agent-hardware campaigns failed.
- Feedback says the moments misfire on the desk or the levels feel like pressure.
- Anthropic ships progress moments in Claude Code or Hardware Buddy itself.

### Best bets, cheapest first

- **Progress, not burn** (small). It is the positioning and the unique feature at once, and it turns the tokenmaxxing backlash from a risk into a reason to choose us.
- **Plan limits through the robot's mood** (small). Usage is the loudest topic: Clawdmeter scored 1,674 and 'I said H and it used 26%' 1,160. The status line already gives us the numbers; the robot makes them feel less like a meter.
- **Win over the people who miss /buddy** (small). 1,197 thumbs-up asked Anthropic to bring the pet back. Aiming the launch at them costs nothing.
- **A deposit list before any hardware** (small). It tells us whether people will pay for a ready-made unit before we spend on one. Vibe Buddy takes a $5 refundable deposit toward $49.
- **Firmware for boards people already own** (medium). It rides the biggest posts (desk hardware, median 306) with no hardware risk, and our moments are what those boards lack: Hardware Buddy's own pet only levels up every 50K tokens.
- **A pacing and wellbeing mode built on drift** (medium). Nobody owns it, the threads about it are busy, and it uses what only Burnbot measures.
- **Explain usage drain turn by turn** (medium). Limit-drain posts draw long threads: '73% of my weekly limit gone in 2 days' got 151 comments. People want to know why, not just how much.

## In numbers

| | |
|---|--:|
| Products found (after merging duplicates) | 1,752 |
| Direct products profiled in full (T1) | 27 |
| Same-job tools profiled in full (T2) | 10 |
| Adjacent gadgets and platform features, short profile (T3) | 18 |
| Corrections made by the fact-checkers | 548 |
| Reddit posts with scores | 47 |

T1 means made for AI coding agents and living outside the terminal: desk hardware, status lights, desktop pets and overlays. T2 does the same job in another form: menu-bar monitors, statuslines, phone and approval apps, dashboards. T3 is general desk gadgets and the AI companies' own features.

## Where Burnbot stands

### What only Burnbot does, or nearly

- **Levels ranked against the user's own last 30 days** 0 of 37 at yes. Clauddy shades its heat map against your busiest day. CodeBurn shows cost as a multiple of your median session. Agent Cat alerts on personal bests. None sets live levels from your own history.
- **Noticing a failing test or build turning green** 0 of 37 at yes. Clawd on Desk, Peon-ping and CodeBurn react when a command fails. None of them notices a failure followed by a pass.
- **"Drifted" when you wander off after Claude hands you the turn** 0 of 37 at yes. Clawd on Desk sleeps after 60 seconds of mouse idle. Lockpaw infers presence from the screen lock. Neither compares against your usual break.
- **A daily wins goal built from outcomes, with a streak** Agent Cat, Viberank and Claude Code's Stats tab have streaks, and all count usage or active days. Hardware Buddy levels up every 50K tokens. No profile describes a goal made of red to green, shipped, PR and plan approved.
- **"Going round": spotting the user's repeated asks (close, not unique)** CodeBurn's Guard stops the agent repeating the same tool call. Claude Code's /usage lists loops. Notchi reacts when a prompt sounds stuck. Burnbot counts 3 near-repeat asks with no progress.
- **One character on desktop, a second monitor and a DIY desk screen** No software companion has a full second-monitor mode at yes. Clawd on Desk adds a phone page, Pixel Agents a browser page, and Agent Cat phone and watch widgets. Burnbot adds a DIY desk screen as well.

### Where Burnbot is behind

- **One agent on one OS** Burnbot supports Claude Code on macOS only. Clawd on Desk covers nearly 30 agents on three OSes, Vibe Island 30, and SlashVibe 20+. Lock-in is the top objection to agent hardware. *Who does it: Clawd on Desk, Vibe Island, SlashVibe V1, Petdex, peon-ping (PeonPing), CodexBar.*
- **No plan limits** 12 of 27 T1 and 5 of 10 T2 show plan limits. Burnbot shows none, and its cost view is only partial. Usage is the loudest topic on r/ClaudeCode. *Who does it: Clawd on Desk, Pixel Agents, Clawdmeter, Clauddy (desktop pet, renatoaug), Vibe Island, CodexBar.*
- **Cannot approve or deny from the robot or the desk screen** 11 of 27 T1 can, including free Clawd on Desk and Vibe Notch, and Anthropic's own Hardware Buddy. Hardware threads call approve and deny the one action that matters. *Who does it: Clawd on Desk, Vibe Notch (formerly Claude Island), Claude Desktop Buddy / Hardware Buddy BLE API, SlashVibe V1, Codex Micro (Work Louder x OpenAI), Vibe Island.*
- **No sound** 15 of 27 T1 play sounds. Peon-ping's voice alerts drew 1,006 Hacker News points and 301 comments. Users ask for a different cue per state and per session. *Who does it: peon-ping (PeonPing), Clawd on Desk, Notchi, Pixel Agents, Vibe Notch (formerly Claude Island), Clauddy (desktop pet, renatoaug).*
- **Only a partial view of several sessions** 16 of 27 T1 show each session. Pixel Agents gives every session its own character. A top request is one light per session that focuses that window when pressed. *Who does it: Pixel Agents, Clawd on Desk, Vibe Island, agentdeck (Ulanzi D200), Notchi, SlashVibe V1.*
- **A narrow, DIY-only desk screen** Two board setups over USB, not sold, and not Hardware Buddy compatible. Clawdmeter flashes 28 boards from a tray app. Hardware Buddy runs on a board of about $30. Vibe Buddy takes $49 pre-orders for a finished unit. *Who does it: Clawdmeter, Claude Desktop Buddy / Hardware Buddy BLE API, Vibe Buddy, ClaudeAssistant (FreakStudio) / 码克助手, a.k.a. Claude Buddy.*
- **One fixed character, no skins or packs** Petdex is built around shareable pets. Peon-ping has 165 voice packs. Pixel Agents has a character designer. Codex pets have a format other tools reuse. *Who does it: Petdex, peon-ping (PeonPing), Pixel Agents, Agent Paperclip, Codex pets (OpenAI).*
- **No licence file and GitHub releases only** The repo is public but has no licence. Clawd on Desk ships AGPL-3.0 through a Homebrew cask, winget and APT. Skeptics warn against running unvetted tools. *Who does it: Clawd on Desk, ccusage, CodexBar, Pixel Agents.*

### Threats

- **HIGH: Anthropic ships the motivation layer itself** Claude Code already has a usage streak, a heatmap, /insights, /recap, Remote Control alerts and status-line limits. They cost nothing extra on a paid plan, though status-line limits reach only Pro, Max and Ultra. A pet that only shows burn or streaks adds little. *Who: Claude Code /usage, /stats, /insights and /recap, Claude Code Remote Control and mobile push, Claude Code status line.*
- **HIGH: Hardware Buddy becomes the default way to build desk hardware** Anthropic's BLE API in the Claude desktop app lets any cheap board show sessions and answer prompts. The reference repo has 2,721 stars and 474 forks, and Espressif has a library for it. It needs developer mode and is labelled not officially supported. Burnbot's USB screen does not speak it. *Who: Claude Desktop Buddy / Hardware Buddy BLE API, Claude Desktop app, Code tab.*
- **HIGH: Free open-source pets already own the waiting and done job** Clawd on Desk is free, AGPL, multi-agent and ships every 8 to 12 days, though it avoids scoring by design. Pixel Agents has 98,492 VS Code installs, and its roadmap mentions scores and game elements. *Who: Clawd on Desk, Pixel Agents, Petdex, peon-ping (PeonPing).*
- **MEDIUM: Funded multi-agent hardware sets what buyers expect** SlashVibe ($143,175) and Codex Micro (sold out in about 12 hours) make status, approve keys and voice the standard. SlashVibe's campaign lists a pixel pet as an SDK example. Its first batch is due to ship in March 2027. *Who: SlashVibe V1, Codex Micro (Work Louder x OpenAI), Ulanzi AU05 Vibe Key, VibeKeys.*
- **MEDIUM: OpenAI makes desktop pets a free commodity** Codex pets track needs you, done and failed across sessions at no extra charge. Their pet format is being reused by other tools. They are Codex only for now. *Who: Codex pets (OpenAI), Codex app (OpenAI).*
- **MEDIUM: Burnbot's own burn framing rides the tokenmaxxing backlash** The name and the top-level fire put token burn first, and burn is 40% of each level. Tokenmaxxing threads about Uber and Amazon drew 293 and 251 HN points. Meta's Claudeonomics leaderboard went down within days. *Who: viberank, Tokscale.*
- **MEDIUM: A flood of clones and fatigue with the whole category** The catalogue lists 261 more desktop companions and 377 more hardware displays. Skeptics call these the vibe-coding hello world. Hobby launches on HN mostly got 1 to 6 points. *Who: Petdex, Clauddy (desktop pet, renatoaug), Agent Paperclip.*
- **LOW: Sessions move into hubs that Burnbot may not see** GitHub Agent HQ, Cursor's agents window, Antigravity and the Claude desktop Code tab run agents outside the terminal. It is unclear whether Burnbot's hooks and logs reach them. *Who: GitHub Agent HQ / agents panel, Cursor Agents Window, Google Antigravity, Claude Desktop app, Code tab.*

### Openings

- **Small effort: Lead with progress: the wins goal and red-to-green, not burn** 0 of 37 products have personal-baseline levels or red-to-green at yes. Skeptics ask to measure outcomes, not consumption. Burnbot already weights typing 35% and actions 25%.
- **Small effort: Show plan limits through the robot, not as another meter** 12 of 27 T1 and 5 of 10 T2 show limits. Pets that sweat near the limit and throw confetti on reset get warm reactions. The status line gives 5-hour and weekly limits at no extra charge, but only to Pro, Max and Ultra subscribers.
- **Small effort: Quiet, distinct sounds per state, off by default** 15 of 27 T1 play sounds. Peon-ping hit 1,006 HN points. Users ask for separate cues for done and needs-input. They also fear being pinged too often, which fits Burnbot's restraint.
- **Small effort: Work with Remote Control by writing its presence file** Claude Code skips phone pushes while CLAUDE_CLIENT_PRESENCE_FILE exists. Burnbot already tracks typing and which app is in front. Lockpaw added the same idea on 7 Nov 2026.
- **Medium effort: Explain usage drain with a per-turn history** A Clawdmeter commenter asked to see how each command affected usage because they could not prove the drain. A post about losing 73% of a weekly limit in 2 days on the $100 plan got 151 comments.
- **Medium effort: A per-session strip that clears when the user answers** 16 of 27 T1 show each session. Threads on parallel sessions drew 100 and 50 comments. Users note no event fires when they answer, so displays get stuck on the old state.
- **Medium effort: Make the desk screen speak Hardware Buddy and flash from the app** Hardware Buddy has 2,721 stars and runs on a board of about $30. Clawdmeter, which flashes 28 boards from its tray app, has 2,349 stars. Hardware Buddy's own pet levels up only every 50K tokens, so Burnbot's moments add something.
- **Medium effort: A wellbeing and pacing mode built on drift** The closest today are Peon-ping's exercise reminders and Clauddy's stretch remark after 90 minutes. A thread on staying in flow while waiting got 307 points and 248 comments. Burnbot already knows the user's usual break.
- **Large effort: Be the brain for hardware others sell** SlashVibe promises an AGPL SDK with a pixel pet as an example. The open-source agentdeck app turns an off-the-shelf Ulanzi D200 pad into an agent console. This reaches hardware buyers without making hardware.

## The market, by category

### Desktop pets and overlays

Free software characters that sit on the desktop and react to agent hooks. Burnbot sits here. The catalogue lists 261 more T1 desktop companions, notch apps included.

Leaders: Pixel Agents, Clawd on Desk, peon-ping (PeonPing), Petdex.

- Clawd on Desk is the closest match to Burnbot. It covers nearly 30 agents and does approvals (not for every agent), one-click jump, plan limits, sound and history.
- Pixel Agents gives each Claude Code session its own character in a pixel office. It has 10,286 stars and 98,492 VS Code installs, and also runs in a browser through its CLI.
- Most pair a character with live status and a permission alert. All of them are free and open source.

### Notch and menu-bar companions

Small always-visible apps in the Mac notch or menu bar. Both paid companion apps in the profiled set sit here: Vibe Island and Fetch, each $19.99 one-time.

Leaders: Vibe Island, Vibe Notch (formerly Claude Island), Notchi.

- Vibe Island covers 30 agents for $19.99 one-time. It can approve from the notch, but only for Claude Code, OpenCode and MiMoCode.
- Agent Cat comes closest to Burnbot's motivation layer. It has streak pins, an AI recap called Reflect, history, personal-best alerts, and phone and watch apps.
- Interest is thin. Notch launches on Hacker News got 1 to 9 points each.

### Agent hardware displays

Desk screens that show agent state. This is the most crowded category, with 377 more T1 names in the catalogue.

Leaders: SlashVibe V1, Claude Desktop Buddy / Hardware Buddy BLE API, Clawdmeter.

- SlashVibe raised $143,175 from 639 backers for a 3.96-inch display with a wireless controller. It lists 20+ agents and promises AGPL code and an SDK.
- Anthropic's Hardware Buddy is an official BLE reference for a board of about $30. It has 2,721 stars and 474 forks, and can answer permission prompts.
- Two finished displays show little pull. Token Monitor's Kickstarter failed at EUR 1,153 of EUR 28,000. FreakStudio's Tindie page shows no units sold.

### Agent hardware controllers

Keypads, knobs and voice remotes for approving and steering agents. The catalogue lists 167 more T1 names.

Leaders: Codex Micro (Work Louder x OpenAI), Ulanzi AU05 Vibe Key, VibeKeys.

- Codex Micro cost $230, sold out in about 12 hours and has no restock. It works with Codex only.
- Approve keys and push-to-talk are the core. None of these is known to have a character or a motivation layer.
- Most crowdfunding here is small: CtrlVibe had 59 backers, V14 had 13 and AgentDeck had 3. Ulanzi's AU05 did better, with 288 backers in Japan.

### Usage and cost monitors

Meters for tokens, cost and plan limits, mostly in the menu bar or CLI. The catalogue lists 317 more T2 and 54 more T1 names.

Leaders: CodexBar, ccusage, CodeBurn.

- CodexBar covers 114 providers and runs on macOS and Linux. It has 23,213 stars.
- CodeBurn is the only profiled product with loop detection at yes. Its opt-in Guard stops a tool call repeated 8 times.
- The basic meter is a commodity. More than 10 near-identical Show HN meters got 1 to 9 points each.

### Gamification and leaderboards

Spend leaderboards, Wrapped-style reports and tamagotchis. The catalogue lists 126 more T2 names.

Leaders: Tokscale, viberank.

- Viberank and Tokscale rank people by spend or tokens. This is the tokenmaxxing style that skeptics mock.
- Tokscale also writes AI session reports that group sessions into 3 to 8 task clusters.

### Orchestration and remote approval

Dashboards and remote apps for running and approving many sessions. The catalogue lists 120 more T2 names in each group.

Leaders: CloudCLI (Claude Code UI).

- CloudCLI has 14,700 stars. It is free to self-host, with hosted plans from EUR 7 a month.
- Remote approval is now first-party for both Claude Code and Codex, so this group is under pressure.

### Platform owners' own features

18 first-party features from Anthropic, OpenAI, Google, GitHub, Cursor, JetBrains and Apple. They set the baseline users get at no extra charge.

Leaders: Claude Code /usage, /stats, /insights and /recap, Claude Desktop app, Code tab, Codex pets (OpenAI).

- Claude Code's /usage Stats tab, also opened by /stats, shows a usage streak, a heatmap and active days. It also has /insights and /recap.
- OpenAI's Codex pets track needs you, done and failed across sessions at no extra charge.
- Agents are moving into hubs such as GitHub Agent HQ, Cursor's agents window and Antigravity.

### What is common and what is rare

- These shares come from the 27 profiled T1 products. These are the most notable products, not a random sample. Table stakes: live agent status (22 of 27, 81%), a permission alert (21 of 27, 78%) and a multi-session view (16 yes, 9 partial).
- About half have sound (15 of 27), physical controls (14), a character (13) or a second screen (13). Burnbot has no sound and only partial multi-session.
- Common but not universal: plan limits (12 of 27 T1, 5 of 10 T2), approving from the device (11 of 27), voice input (9 of 27) and jump to the session (8 yes, 6 partial). Cost is a T2 staple at 8 of 10.
- Rare: history dashboards (4 of 27 T1, 5 of 10 T2), streaks or goals (3 of 37 at yes), AI session recaps (Agent Cat and Tokscale), leaderboards (Viberank and Tokscale) and loop detection (CodeBurn only).
- Nobody has these at yes across all 37: levels ranked against your own history (4 partial), a failing test or build turning green (6 partial), and drifting away while the agent waits (9 partial). Burnbot has all three.
- Many cells are unknown, mostly for hardware. SlashVibe is unknown on 9 of 20 features, including plan limits and every motivation feature. Unknown is not the same as absent.

## Feature matrix

Every product profiled in full, checked against the same 20 points. ● yes · ◐ partly · · no · ? not shown on any page we read (which is not the same as no). Burnbot is the first row.

### Direct products (T1)

| Product | Maker | Form | Platforms | Agents | Price | Stage | Traction |
|---|---|---|---|---|---|---|---|
| **Burnbot** (us) | us | desktop-pet, desktop-overlay, hardware-display | macOS | Claude Code | Free | Released |  |
| [Agent Cat](https://agentcat.app) | Trappist (트라피스트); representative and developer Seokyong Kim (김석용), GitHub yong076 | menu-bar, notch-app, mobile-app, watch-app, other | macOS, Windows, iOS, Android | Claude Code (CLI, desktop app, Cowork), Codex (CLI and app), Gemini CLI +9 | Free | Released | 59 stars, -1 backers, $-1 raised |
| [Agent Paperclip](https://github.com/fredruss/agent-paperclip) | Fred Russias (GitHub: fredruss; HN: fredrussias), Founding Engineer at Leopard Labs and CTO/co-founder of Sourcing Playground according to his GitHub bio. A solo side project with one outside contributor (markmackaycat, who wrote the Gandalf pack). | desktop-pet, desktop-overlay | macOS, Windows, Linux | Claude Code, Codex CLI | Free | Released | 31 stars, -1 backers, $-1 raised |
| [AgentDeck](https://www.kickstarter.com/projects/agentdeck/agentdeck-the-physical-control-deck-for-ai-coding-agents) | Kickstarter creator 'tope' (profile kickstarter.com/profile/agentdeck). The companion software is published by the GitHub org xuan-team, with every commit by 'topelinux'. The demo video is on the YouTube channel '杰杨'. | hardware-controller, hardware-display, desktop-overlay, menu-bar | macOS, Windows | Claude Code, Codex CLI, ChatGPT Desktop / Codex +4 | Kickstarter campaign (Oct 2 - Dec 1, 202… | Crowdfunding now | 1 stars, 3 backers, $-1 raised |
| [agentdeck (Ulanzi D200)](https://github.com/jakeparkcolde/agentdeck) | Coldbyte (GitHub: jakeparkcolde), a solo developer. Most commits are co-authored with Claude. | hardware-display, hardware-controller | macOS | Claude Code, Codex CLI, Antigravity CLI (agy): quota over SSH, and counted as 'A' on the agents page +3 | Free | Released | 51 stars, -1 backers, $-1 raised |
| [Clauddy (desktop pet, renatoaug)](https://github.com/renatoaug/claude-usage-monitor) | Renato Augusto (GitHub: renatoaug) | desktop-pet, desktop-overlay, menu-bar | macOS, Windows, Linux | Claude Code, Codex, Cursor | Free | Released | 125 stars, -1 backers, $-1 raised |
| [Clauddy for Divoom MiniToo (bugzmanov)](https://github.com/bugzmanov/divoom-minitoo) | bugzmanov (GitHub user; profile display name 'rafael bugzmanov') | hardware-display | macOS | Claude Code | Free | Hobby project | 25 stars, -1 backers, $-1 raised |
| [Claude Desktop Buddy / Hardware Buddy BLE API](https://github.com/anthropics/claude-desktop-buddy) | Anthropic | hardware-display, protocol-sdk | macOS, Windows, device-only | Claude Code (inside the Claude desktop app; repo About says 'Claude Code Desktop'), Claude Cowork | Free | Released | 2,721 stars, -1 backers, $-1 raised |
| [claude-code-buddy (TaoXieSZ)](https://github.com/TaoXieSZ/claude-code-buddy) | Tao Xie (GitHub: TaoXieSZ), an individual developer | hardware-display, desk-robot, hardware-controller | macOS | Claude Code, Claude Desktop, Cursor +3 | Free | Hobby project | 8 stars, -1 backers, $-1 raised |
| [ClaudeAssistant (FreakStudio) / 码克助手, a.k.a. Claude Buddy](https://www.tindie.com/products/freakstudio/claudeassistant/) | FreakStudio (Freak嵌入式 / FreakStudioCN), an embedded firmware/IoT studio. All commits are by GitHub user leezisheng. | hardware-display, status-light | Windows, device-only | Claude Code | $70 | Shipping | 9 stars, -1 backers, $-1 raised |
| [Clawd on Desk](https://github.com/rullerzhou-afk/clawd-on-desk) | rullerzhou-afk (GitHub display name 'Ruller_Lulu'), with co-maintainers @YOIMIYA66 and @Bynlk (Mobile/PWA) and community contributors | desktop-pet, web-app | macOS, Windows, Linux, web | Claude Code, Codex CLI, GitHub Copilot CLI +28 | Free | Released | 6,777 stars, -1 backers, $-1 raised |
| [Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter) | Hermann Haraldsson (GitHub: HermannBjorgvin), a software developer who says he is 'not an embedded developer' and built it with Claude's help. | hardware-display, hardware-controller, menu-bar | macOS, Windows, Linux | Claude Code, OpenAI Codex CLI (trial: usage meters and reset credits only, no mascot reactions) | $30 | Released | 2,349 stars, -1 backers, $-1 raised |
| [Codex Micro (Work Louder x OpenAI)](https://learn.chatgpt.com/docs/features/codex-micro) | Work Louder, in collaboration with OpenAI (sold through OpenAI Supply Co. and Work Louder) | hardware-controller, status-light | macOS, Windows | OpenAI Codex (in the ChatGPT desktop app) | $230 | Released | -1 stars, -1 backers, $-1 raised |
| [CtrlVibe](https://www.pledgebox.com/projects/ctrlvibe-ai-keyboard-workflow-control-console-for-the-ai-era) | CtrlVibe | hardware-controller, status-light | macOS, Windows | Claude Code, Cursor, Codex +7 | $139 | Campaign ended | -1 stars, 59 backers, $10,261 raised |
| [Fetch (tryfetch.dev)](https://tryfetch.dev/) | Not named on the site. The Polar organisation is simply called 'Fetch' (slug tryfetch). The HN submitter 'laithistaken' and the Discord invite creator (display name 'Laith !') suggest a solo maker named Laith, but this is unverified. | notch-app | macOS | Claude Code, Codex | $20 | Released | -1 stars, -1 backers, $-1 raised |
| [Keychron AI companion for vibe coding (unnamed mic concept)](https://www.pcgamer.com/software/ai/keychron-is-experimenting-with-a-mic-equipped-mini-keeb-that-lets-you-chat-to-your-ai-agent-while-it-vibe-codes-and-i-have-my-head-in-my-hands/) | Keychron | hardware-controller | unknown |  | No price announced; concept teaser only … | Concept | -1 stars, -1 backers, $-1 raised |
| [Lockpaw](https://github.com/sorkila/lockpaw) | Erik Nielsen (GitHub: sorkila) | menu-bar, desktop-overlay | macOS | Claude Code, Codex CLI, Gemini CLI +4 | Free | Released | 184 stars, -1 backers, $-1 raised |
| [Notchi](https://github.com/sk-ruban/notchi) | Ruban (GitHub: sk-ruban). A personal open-source project: the profile lists the website ruban.sk and membership in the greptileai GitHub org, and the notchi.app footer reads '© 2026 Ruban' and links to skruban.com. | notch-app | macOS | Claude Code, OpenAI Codex (CLI and desktop app), T3 Code (a host app: jump-to-host support in v1.2.6) +1 | Free | Released | 1,051 stars, -1 backers, $-1 raised |
| [Petdex](https://petdex.dev) | Crafter Station, led by Railly Hugo (@Railly) | desktop-pet, desktop-overlay, web-app | macOS, Windows, Linux, web | Claude Code, Codex CLI, Gemini CLI +8 | Free | Released | 4,400 stars, -1 backers, $-1 raised |
| [Pixel Agents](https://github.com/pablodelucca/pixel-agents) | Pablo De Lucca (GitHub org pixel-agents-hq) | ide-extension, web-app | macOS, Windows, Linux, web | Claude Code | Free | Released | 10,300 stars, -1 backers, $-1 raised |
| [SlashVibe V1](https://slashvibe.ai/) | SlashVibe (Natural Mapping, Inc., dba SlashVibe). The Kickstarter creator is listed as 'Loda', and a LinkedIn search result names 'Loda Luo - SlashVibe'. Industrial design by dooo design (Changliang Liu, Yitian Wu, Shijun Xu). | hardware-display, hardware-controller, protocol-sdk | macOS, Windows | Claude Code (CLI and Desktop), Codex (CLI and Desktop), GitHub Copilot CLI +18 | $189 | Crowdfunding now | -1 stars, 639 backers, $143,175 raised |
| [Token Monitor (Fractal Manifold)](https://tokenmonitor.dev/) | Fractal Manifold (a deep-learning research and consulting lab; maker Jorge, Kickstarter user 'jorgemf') | hardware-display, cli-statusline | macOS, Linux | Claude Code, Codex CLI, Antigravity CLI | $115 | Campaign ended | 4 stars, 10 backers, $1,340 raised |
| [Ulanzi AU05 Vibe Key](https://www.ulanzi.com/products/au05-vibe-key-ai-voice-input-keypad-i018) | Ulanzi | hardware-controller, status-light | macOS, Windows | Claude Code, OpenAI Codex, ChatGPT (voice input target) +2 | $60 | Released | -1 stars, 288 backers, $19,800 raised |
| [V14 (MicStick V14) – The AI Workflow Console That Keeps You in the Flow](https://www.pledgebox.com/projects/v14-the-ai-coding-remote-that-keeps-you-in-the-flow) | MicStickV14 (Kickstarter creator handle). PledgeBox shows 4 collaborators without names. | hardware-controller | macOS, Windows | Claude (Claude Code implied by 'AI coding remote'), Codex, other AI coding agents (campaign subtitle; which ones is not stated) +1 | reward-tier and retail prices are not vi… | Campaign ended | -1 stars, 13 backers, $2,018 raised |
| [Vibe Buddy](https://vibebuddy.sh/) | Volodymyr 'Vova' Pytsiuk (GitHub vovapyc, profile name 'Vova Pytsiuk'; X @vovawed) and Alize (GitHub aalizelau; no surname on the profile or site) | hardware-display, desk-robot | macOS, Windows, Linux | Codex, Claude Code | $49 | Pre-order | -1 stars, -1 backers, $-1 raised |
| [Vibe Island](https://vibeisland.app) | Edward Luo, a solo developer. The site credits 'Built by Edward' and links to x.com/edwardluox; the full name comes from earlyterms.com. The launch post on @imedwardluo is attributed from a search snippet only. | notch-app, desktop-overlay | macOS | Claude Code, Codex, Gemini CLI +28 | $20 | Released | 163 stars, -1 backers, $-1 raised |
| [Vibe Notch (formerly Claude Island)](https://github.com/farouqaldori/vibe-notch) | Farouq Aldori (maintainer; CTO at Opper AI, previously co-founder and CTO of FinetuneDB). The v1.3 release credits eight community contributors. | notch-app, menu-bar | macOS | Claude Code | Free | Released | 2,500 stars, -1 backers, $-1 raised |
| [VibeKeys](https://vibekeys.dev/) | Second State Inc., which also makes the EchoKit voice device and hosts WasmEdge-related repos under the second-state GitHub org | hardware-controller, hardware-display | macOS, Windows, Linux | Claude Code, OpenAI Codex, Cursor +5 | $39 | Shipping | 14 stars, -1 backers, $-1 raised |

**Seeing and acting on sessions**

| Product | Status | Several sessions | Needs-you alert | Approve from it | Jump to session | Tokens / cost | Plan limits | Own screen | Buttons | Voice input | Sound |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Burnbot** | ● | ◐ | ● | · | ● | ◐ | · | ● | ◐ | · | · |
| Agent Cat | ● | ◐ | ◐ | · | ? | ● | ● | ◐ | · | ? | ? |
| Agent Paperclip | ● | ◐ | ● | · | · | ◐ | ● | · | · | · | ● |
| AgentDeck | ● | ● | ● | ● | ● | ◐ | ◐ | ● | ● | ◐ | ● |
| agentdeck (Ulanzi D200) | ● | ● | ● | · | ● | ◐ | ● | ● | ● | · | ◐ |
| Clauddy (desktop pet, renatoaug) | ● | ◐ | ◐ | · | · | ● | ● | · | · | · | ● |
| Clauddy for Divoom MiniToo (bugzmanov) | ● | ◐ | ● | · | · | · | · | ● | · | · | · |
| Claude Desktop Buddy / Hardware Buddy BLE API | ● | ◐ | ● | ● | · | ● | · | ● | ● | · | ● |
| claude-code-buddy (TaoXieSZ) | ● | ● | ● | ● | ◐ | ● | ● | ● | ● | ● | ● |
| ClaudeAssistant (FreakStudio) / 码克助手, a.k.a. Claude Buddy | ● | ● | ● | · | · | · | · | ● | ● | · | ● |
| Clawd on Desk | ● | ● | ● | ● | ● | ◐ | ● | ◐ | · | ? | ● |
| Clawdmeter | ◐ | ◐ | ● | ◐ | ? | ◐ | ● | ● | ● | ◐ | ● |
| Codex Micro (Work Louder x OpenAI) | ● | ● | ● | ● | ● | · | · | · | ● | ● | · |
| CtrlVibe | ◐ | ◐ | ? | ◐ | ◐ | ● | ? | ● | ● | ● | · |
| Fetch (tryfetch.dev) | ● | ● | ● | ● | ● | ? | ? | · | · | ● | ? |
| Keychron AI companion for vibe coding (unnamed mic concept) | ? | ? | ? | ? | ? | ? | ? | · | ● | ● | ? |
| Lockpaw | ◐ | ● | ● | · | ? | · | · | ◐ | · | · | ● |
| Notchi | ● | ● | ● | ◐ | ◐ | ● | ● | · | · | · | ● |
| Petdex | ● | ● | ● | ? | ◐ | ? | ? | ? | · | ? | ● |
| Pixel Agents | ● | ● | ● | ◐ | ● | ◐ | ● | ◐ | · | · | ● |
| SlashVibe V1 | ● | ● | ● | ● | ● | ◐ | ? | ● | ● | ● | ◐ |
| Token Monitor (Fractal Manifold) | · | · | · | · | · | ● | ● | ● | ● | · | ● |
| Ulanzi AU05 Vibe Key | ● | ◐ | ● | ◐ | ? | · | · | · | ● | ● | ? |
| V14 (MicStick V14) – The AI Workflow Console That Keeps You in the Flow | ● | ● | ◐ | ● | ? | ? | ? | ● | ● | ● | ? |
| Vibe Buddy | ● | ◐ | ● | · | · | ◐ | ● | ● | · | · | · |
| Vibe Island | ● | ● | ● | ● | ● | ◐ | ● | · | · | · | ● |
| Vibe Notch (formerly Claude Island) | ● | ● | ● | ● | ◐ | ◐ | · | · | · | · | ● |
| VibeKeys | ● | ● | ● | ● | ◐ | ◐ | ? | ● | ● | ● | · |

**Insight and character**

| Product | Levels vs you | Red to green | Loops / stuck | Drift / away | AI recap | History | Streaks / goals | Leaderboard | Character |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Burnbot** | ● | ● | ● | ● | ● | ● | ● | · | ● |
| Agent Cat | ◐ | ? | ? | ? | ● | ● | ● | ◐ | ● |
| Agent Paperclip | · | · | · | · | · | · | · | · | ● |
| AgentDeck | · | · | · | · | · | · | · | · | · |
| agentdeck (Ulanzi D200) | · | · | · | · | · | · | · | · | · |
| Clauddy (desktop pet, renatoaug) | ◐ | · | · | ◐ | · | ● | · | · | ● |
| Clauddy for Divoom MiniToo (bugzmanov) | · | · | · | · | · | · | · | · | ● |
| Claude Desktop Buddy / Hardware Buddy BLE API | · | · | · | · | · | · | ● | · | ● |
| claude-code-buddy (TaoXieSZ) | · | ◐ | ? | ? | ◐ | · | ◐ | · | ● |
| ClaudeAssistant (FreakStudio) / 码克助手, a.k.a. Claude Buddy | · | ◐ | · | · | · | · | · | · | ● |
| Clawd on Desk | · | ◐ | · | ◐ | · | ● | · | · | ● |
| Clawdmeter | · | · | · | ◐ | · | · | · | · | ● |
| Codex Micro (Work Louder x OpenAI) | · | · | · | · | · | · | · | · | · |
| CtrlVibe | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Fetch (tryfetch.dev) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Keychron AI companion for vibe coding (unnamed mic concept) | ? | ? | ? | ? | ? | ? | ? | ? | · |
| Lockpaw | · | · | · | ◐ | · | · | · | · | ◐ |
| Notchi | · | ◐ | ◐ | ◐ | · | ● | · | · | ● |
| Petdex | ? | ? | ? | ? | ? | ? | ? | ◐ | ● |
| Pixel Agents | · | · | · | · | · | ◐ | · | · | ● |
| SlashVibe V1 | ? | ? | ? | ? | ? | ? | ? | ? | ◐ |
| Token Monitor (Fractal Manifold) | · | · | · | · | · | · | · | · | ◐ |
| Ulanzi AU05 Vibe Key | · | ? | ? | ? | ? | ? | ? | ? | · |
| V14 (MicStick V14) – The AI Workflow Console That Keeps You in the Flow | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Vibe Buddy | · | · | · | · | · | · | · | · | ● |
| Vibe Island | · | · | · | ◐ | ◐ | · | · | · | ◐ |
| Vibe Notch (formerly Claude Island) | · | · | · | ◐ | · | · | · | · | ◐ |
| VibeKeys | · | ? | · | · | ? | ? | ? | ? | · |

### Same-job tools (T2)

| Product | Maker | Form | Platforms | Agents | Price | Stage | Traction |
|---|---|---|---|---|---|---|---|
| **Burnbot** (us) | us | desktop-pet, desktop-overlay, hardware-display | macOS | Claude Code | Free | Released |  |
| [c9watch](https://github.com/minchenlee/c9watch) | Min-Chen (Vincent M.C.) Lee, GitHub minchenlee (mclee.dev), with 11 outside contributors listed in the README | menu-bar, web-app, other | macOS, Linux, web | Claude Code, OpenAI Codex (CLI and Codex App), Cursor Agent (monitor-only) +2 | Free | Released | 137 stars, -1 backers, $-1 raised |
| [ccusage](https://github.com/ryoppippi/ccusage) | ryoppippi (open-source maintainer; ccusage GitHub org) | cli-statusline, other | macOS, Linux, Windows | Claude Code, Codex, OpenCode +17 | Free | Released | 19,486 stars, -1 backers, $-1 raised |
| [Claude Code Tamagotchi](https://github.com/Ido-Levi/claude-code-tamagotchi) | Ido Levi (GitHub: Ido-Levi; npm: idohlevi; X: the_ido_levi), an individual developer who also made the Hephaestus agent framework | cli-statusline | macOS, Linux | Claude Code | Free | Released | 438 stars, -1 backers, $-1 raised |
| [CloudCLI (Claude Code UI)](https://github.com/siteboon/claudecodeui) | Siteboon (GitHub org 'siteboon', site siteboon.ai; product site cloudcli.ai, branded 'CloudCLI') | web-app, mobile-app, other | macOS, Windows, Linux, iOS, Android, web | Claude Code, Cursor CLI, Codex +2 | Free | Released | 14,700 stars, -1 backers, $-1 raised |
| [CodeBurn](https://github.com/getagentseal/codeburn) | AgentSeal (open-source AI agent security project), founded by Resham Joshi (GitHub: iamtoruk) | menu-bar, desktop-overlay, web-app, ide-extension, cli-statusline, other | macOS, Windows, Linux, web | Claude Code, Claude Desktop, Amp +41 | Free | Released | 11,859 stars, -1 backers, $-1 raised |
| [CodexBar](https://github.com/steipete/CodexBar) | Peter Steinberger (steipete), ex-founder of PSPDFKit and creator of OpenClaw. His GitHub profile lists OpenAI as his company ('Now at OpenAI, working on agents'). | menu-bar, other | macOS, Linux | Codex, Claude Code, Cursor +15 | Free | Released | 23,200 stars, -1 backers, $-1 raised |
| [peon-ping (PeonPing)](https://peonping.com) | Tony (GitHub tonyyont, original author; listed as Tony Sheng in the Product Hunt launch team) and Gary Sheng (co-creator and maintainer). The project now lives in the PeonPing GitHub org, with community contributors. | desktop-overlay, desktop-pet, other | macOS, Linux, Windows | Claude Code, Codex, Cursor +20 | Free | Released | 5,100 stars, -1 backers, $-1 raised |
| [Tokscale](https://tokscale.ai) | Junho Yeo (GitHub: junhoyeo), with community contributors. Early December 2025 commits published packages under the 0xinevitable npm scope with Inevitable branding before the `tokscale` package. | cli-statusline, web-app | macOS, Windows, Linux, web | Claude Code, Codex CLI, Cursor IDE +33 | Free | Released | 5,900 stars, -1 backers, $-1 raised |
| [Usagebar](https://usagebar.com/) | Aryan Bhasin (listed as maker on Product Hunt) | menu-bar | macOS | Claude Code | $9 | Released | -1 stars, -1 backers, $-1 raised |
| [viberank](https://viberank.app) | SCULPT (GitHub org sculptdotfun, which describes itself as a 'curiosity collective', sculpt.fun; npm author of viberank-cli). The current main committer is Nikshep Saravanan (nikshepsvn), who also makes Tako, an open-source Mac terminal for running many agents. CHANGELOG v2.0 notes that the original npm package names belong to 'the original author'. | web-app, other | web, macOS, Windows, Linux | Claude Code, OpenAI Codex, Gemini CLI +16 | Free | Released | 121 stars, -1 backers, $-1 raised |

**Seeing and acting on sessions**

| Product | Status | Several sessions | Needs-you alert | Approve from it | Jump to session | Tokens / cost | Plan limits | Own screen | Buttons | Voice input | Sound |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Burnbot** | ● | ◐ | ● | · | ● | ◐ | · | ● | ◐ | · | · |
| c9watch | ● | ● | ● | · | ● | ● | ● | ◐ | · | · | ◐ |
| ccusage | · | ◐ | · | · | · | ● | ◐ | · | · | · | · |
| Claude Code Tamagotchi | ◐ | ◐ | · | · | · | · | · | · | · | · | · |
| CloudCLI (Claude Code UI) | ● | ● | ● | ● | ● | ● | ◐ | · | · | ● | ● |
| CodeBurn | ◐ | ◐ | · | · | · | ● | ● | · | · | · | ? |
| CodexBar | ◐ | ● | · | · | ● | ● | ● | · | · | · | ? |
| peon-ping (PeonPing) | ● | ● | ● | · | ● | · | · | · | · | · | ● |
| Tokscale | · | ◐ | · | · | · | ● | ● | · | · | · | · |
| Usagebar | · | · | · | · | · | ● | ● | · | · | · | ? |
| viberank | · | · | · | · | · | ● | · | · | · | · | · |

**Insight and character**

| Product | Levels vs you | Red to green | Loops / stuck | Drift / away | AI recap | History | Streaks / goals | Leaderboard | Character |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Burnbot** | ● | ● | ● | ● | ● | ● | ● | · | ● |
| c9watch | · | · | · | · | · | ● | · | · | · |
| ccusage | ◐ | · | · | · | · | ◐ | · | · | · |
| Claude Code Tamagotchi | · | · | ◐ | ◐ | ◐ | · | · | · | ● |
| CloudCLI (Claude Code UI) | · | · | · | · | · | ◐ | · | · | · |
| CodeBurn | ◐ | ◐ | ● | · | · | ● | · | · | · |
| CodexBar | · | · | · | · | · | ● | · | · | · |
| peon-ping (PeonPing) | · | ◐ | ◐ | ◐ | · | · | ◐ | · | ● |
| Tokscale | · | · | · | · | ● | ● | ◐ | ● | · |
| Usagebar | · | · | · | · | · | · | · | · | · |
| viberank | · | · | · | · | · | ● | ● | ● | · |

### How common each feature is among the 27 direct products

| Feature | Yes | Partly | Share with it | Burnbot |
|---|--:|--:|--:|:-:|
| Status | 22 | 3 | 93% | ● |
| Several sessions | 16 | 9 | 93% | ◐ |
| Needs-you alert | 21 | 3 | 89% | ● |
| Character | 13 | 5 | 67% | ● |
| Tokens / cost | 7 | 11 | 67% | ◐ |
| Sound | 15 | 2 | 63% | · |
| Own screen | 13 | 4 | 63% | ● |
| Approve from it | 11 | 5 | 59% | · |
| Buttons | 14 | 0 | 52% | ◐ |
| Jump to session | 8 | 6 | 52% | ● |
| Plan limits | 12 | 1 | 48% | · |
| Voice input | 9 | 2 | 41% | · |
| Drift / away | 0 | 7 | 26% | ● |
| History | 4 | 1 | 19% | ● |
| Red to green | 0 | 4 | 15% | ● |
| Streaks / goals | 2 | 1 | 11% | ● |
| AI recap | 1 | 2 | 11% | ● |
| Levels vs you | 0 | 2 | 7% | ● |
| Leaderboard | 0 | 2 | 7% | · |
| Loops / stuck | 0 | 1 | 4% | ● |

## What people ask for

- The sharpest pain is missing the moment the agent waits or finishes. "My Claude Code now calls my phone when it needs me" scored 466 with 77 comments.
- Usage is the loudest topic on r/ClaudeCode. Clawdmeter scored 1,674 and "I said H and it used 26%" scored 1,160 with 245 comments. A plain meter is seen as solved. People want to know why usage drains.
- Desk hardware gets the biggest upvotes: Clawdmeter 1,674, a desk lamp 1,637, VibeKeys 1,010. But commenters assume they can build one for $10 to $40, and mock sold units as a flashed M5Stack for 10x the price.
- Waiting and wellbeing is an open lane. A flow-state thread got 307 points and 248 comments. "10x more productive, but mentally exhausted" got 306. The Waiting Room plugin got 983.
- Gamifying token volume backfires. A post mocking $50,000 burned in 30 days got 317 points and 182 comments. A friends' burn leaderboard got only 20.
- Personality is loved, but it has to feel fair. The Bring Back Buddy issue has 1,197 thumbs-up. "They removed the buddy" got 79 comments. Random bad rolls draw complaints.
- Parallel sessions hurt, and comments beat scores. A thread on managing parallel sessions got 34 points but 100 comments. People want one light per session that jumps to it.

### The strongest themes, with what people said

**Lock-in to a single agent or vendor is the main objection, and buyers want hardware that works with whatever agent they use (especially Claude Code)** (Crowdfunding comments)

The biggest complaint about OpenAI's $230 Codex Micro was that it only works with Codex. Claude Code users reverse-engineered it, wrote bridges for it, and filed a 'we need a Claude Code keyboard' request. The campaigns that raised the most money (SlashVibe, Harness) lead with '20+ agents'. Desktop-companion repos get a steady flow of 'please support agent X' issues. Support for many agents is now expected, not a selling point.

> "$230 for essentially a fancy numpad that's only useful for one tool?" ([Hacker News, Codex Micro thread (LetsGetTechnicl), 2026-07-15](https://news.ycombinator.com/item?id=48923724))

> "only talks to OpenAI's ChatGPT desktop app, I only use Claude Code" ([VenTech Digital blog (owner who reverse-engineered the pad), 2026-07-24](https://www.ventechdigital.com/blog/reverse-engineering-the-codex-micro-for-claude-code))

**Price skepticism and 'I can build this with a Stream Deck or a cheap macropad'** (Crowdfunding comments)

Many people think a dedicated agent keypad is overpriced for what it does, since all the logic runs on the PC. They point to Stream Deck or generic macropads, or to cheaper unbranded hardware. Dozens of free Stream Deck plugins for Claude Code approvals and status exist, which caps what people will pay for single-purpose hardware. The press echoes this.

> "This is just a Macropad, right? All of the smarts are on the PC side. So why is it so expensive?" ([Hacker News, Codex Micro thread (joshmarinacci), 2026-07-15](https://news.ycombinator.com/item?id=48923079))

> "Pretty sure I could just vibe code this with my old Elgato Stream Deck." ([Hacker News, Codex Micro thread (kylemaxwell), 2026-07-15](https://news.ycombinator.com/item?id=48923079))

**The job people actually want done: 'tell me which agent needs a decision' at a glance** (Crowdfunding comments)

The feature that gets the most praise is not typing input. It is ambient status: a light or key per session that shows which agent is waiting, finished or stuck. People running several agents say the pain is not knowing when they are needed. This is also the main reason vendors give (ClawMetry, Harness), and it is what owners like most about the Codex Micro.

> "I actually have this as a problem with Codex / Claude where I don't know if I have to make a decision." ([Hacker News (zitterbewegung), 2026-07-15](https://news.ycombinator.com/item?id=48924099))

> "This design looks great though, status lights are a nice touch." ([Hacker News (pwython), 2026-07-15](https://news.ycombinator.com/item?id=48923662))

**Approve / deny is the one action that matters, and people want it on a physical button** (Crowdfunding comments)

Users joke that agent work comes down to 'accept' and 'accept all'. Hobbyist builds and Stream Deck plugins all ship Approve, Always Allow and Deny keys, and the reference firmware for Anthropic's hardware buddy gets PRs for approval countdowns and response-time stats. Demand is real but cheap to meet in software, which makes it hard to charge a hardware premium for.

> "Someday my kid is going to ask me why we need 79 keys on a keyboard if we only use 'accept' and 'accept all'." ([Hacker News (plutomeetsyou), 2026-07-15](https://news.ycombinator.com/item?id=48925155))

> "Approve, Always Allow, Deny keys that mirror the three options Claude Code shows in the terminal" ([GitHub (agent-vitals Stream Deck plugin README, paraphrase)](https://github.com/vladatman/agent-vitals))

**Tokens are not productivity: leaderboards and burn-bragging get mocked as a Goodhart's-law trap** (Skeptics)

This is the loudest skeptic signal. Developers compare token counts to lines of code. They say any token leaderboard gets gamed, and they mock public burn-flexing as addiction or wasted money. Big-company leaderboards were shut down or disowned in 2026: Meta's 'Claudeonomics' went down within days, Shopify renamed its board to a usage dashboard, and Microsoft told engineers tokenmaxxing is 'not what we are optimizing for'. Usage data backs the skeptics: TechCrunch cites Jellyfish finding 2x throughput at 10x token cost. Show HN usage leaderboards (Straude, CCLeaderboard) draw replies like 'Claude golf' and 'I hope it's a joke'. Rate-limit cuts in Aug 2025 were partly blamed on leaderboard flexers.

> "A leaderboard of who can blow the most tokens/money?" ([HN, Show HN: Strava for Claude Code (nusl), 2026-02-18](https://news.ycombinator.com/item?id=47066563))

> "AI output in our work should be measured in engineering progress, not in use metrics, right?" ([HN, Strava for Claude Code (maxverse), 2026-02-18](https://news.ycombinator.com/item?id=47066619))

**"Just use a notification hook / tmux": the gadget or app is redundant with free built-ins** (Skeptics)

The most common dismissal of companion apps, remote-control tools and status displays is that Claude Code hooks, the terminal bell, tmux/screen or Tailscale already do the job. Session managers get called 'a tmux wrapper'. Remote control gets called 're-invented GNU screen'. Commenters on music/voice notification plugins point to the built-in Notification hook. Some say Claude has become good enough at notifying that they removed their own hooks. Even the Clawdmeter maker admits the device is 'not replacing anything'.

> "you can also just add a Notification Hook (/hooks)" ([HN, Show HN: Claude Code plugin to play music when waiting on input (vunderba), 2025-12-20](https://news.ycombinator.com/item?id=46337686))

> "Curious why you aren't using Claude Code's stop/notification hook" ([HN, cmux Show HN (lawrencechen), 2026-02-20](https://news.ycombinator.com/item?id=47082036))

**Overpriced single-purpose desk hardware: 'a reskinned macropad' and 'a more limited Stream Deck'** (Skeptics)

OpenAI's Codex Micro keypad (Work Louder, about $230) drew the biggest hardware reaction: 306 pts and 253 comments on HN as of 2026-11-18. Roughly two thirds of the first 30 top-level comments were skeptical. Commenters called it a rebadged Work Louder Creator Micro 2 and compared it unfavourably with a $50 Stream Deck that has dynamic LCD keys. Others called it vendor lock-in (Codex-only, no Linux) or a marketing gimmick that people stop caring about after a day. Someone built an open-source clone for $40. Reviewers say the lights show task status, not whether the agent's output is correct.

> "This is a rebranded/reskinned WORK LOUDER Creator Micro 2 btw" ([HN, OpenAI Codex Micro launch thread (paxys), 2026-07-15](https://news.ycombinator.com/item?id=48923079))

> "$230 for essentially a fancy numpad that's only useful for one tool?" ([HN, Codex Micro thread (LetsGetTechnicl), 2026-07-15](https://news.ycombinator.com/item?id=48923079))

**Commodity and 'Sherlock' risk: every dev vibe-codes one, and first-party platforms will ship it** (Skeptics)

Skeptics say these tools are trivially cloneable ('the vibe coding equivalent of hello world', '50 clones in the comment section'). They expect Anthropic, OpenAI and Google to ship the same features, and that has already happened: Claude Code Remote Control, the Desktop Buddy BLE API, the /usage command, and OpenAI's own Micro keypad. Free open-source trackers undercut paid ones, and YC-funded wrappers get openly mocked.

> "this is the vibe coding equivalent of 'hello world' at this stage." ([HN, Show HN: CC Usage Bar menu-bar usage app (bazhand), 2026-03-07](https://news.ycombinator.com/item?id=47292378))

> "Its hilarious how there's 50 clones of the same thing in the comment section" ([HN, Launch HN: Omnara (dakolli), 2026-02-12](https://news.ycombinator.com/item?id=46993224))

**"Tell me which agent needs me": demand for attention signals (sound, voice, pings)** (Hacker News)

This is the biggest pull on HN. The Warcraft III Peon voice-notification post for Claude Code was one of the most upvoted posts in this whole category: 1006 points and 301 comments as of 2026-11-18. It was quickly ported to Codex and Windsurf. Across many smaller Show HNs, people say the same thing: agents block silently on permission prompts, users lose track of which terminal or pane is waiting, and they drift off while they wait. Requests go beyond 'a ping' to 'which session, and what state'. A vocal minority dislikes notifications altogether, or only finds them useful for long tasks.

> "Warcraft III Peon Voice Notifications for Claude Code (1006 points, 301 comments as of 2026-11-18)" ([HN story, 2026-02-12](https://news.ycombinator.com/item?id=46985151))

> "But I have to admit, making it fun like this beats it by a lot." ([HN comment, bothlabs, Peon-ping thread, 2026-02-12](https://news.ycombinator.com/item?id=46985729))

**Parallel-agent overload: people want one glanceable view across many sessions** (Hacker News)

Power users run 3 to 12 or more agents in tmux, cmux or Ghostty tabs and struggle to keep track of them. Several self-limit because of anxiety. Multi-session tools draw real engagement: cmux got 198 points and Vibe Kanban 195 points (as of 2026-11-18), and a long tail of tmux/TUI dashboards (Amux, claude-dashboard, Corral, Batty, herdr) keeps appearing. The counter-arguments are that these tools drift into reinventing an IDE and that many are buggy.

> "new flow state is having 10 terminal tabs in diff worktrees and trying to remember what each bit is" ([HN comment, tombot, Ask HN: experimenting with LLMs for coding, 2026-07-03](https://news.ycombinator.com/item?id=48779017))

> "I try not to run more than three sessions at once, or I get anxiety" ([HN comment, marshalla, Ask HN: What's your current AI agentic setup?, 2026-11-04](https://news.ycombinator.com/item?id=50366117))

**Usage and limit anxiety drives demand for monitors, but the menu-bar monitor is commoditized** (Hacker News)

Limit cuts and opaque usage drive constant HN threads, and usage tools get traction: CodeBurn 112 points, ccusage 75 points (as of 2026-11-18). Users feel pressure to 'use it or lose it' before resets, and fear surprise overage. Users want more than raw tokens: cost per session, where the waste goes, and forecasts. The flip side is that dozens of near-identical menu-bar meters exist (Claude Meter, ClaudeWatch, CC Usage Bar, Claude Battery, LimitBar, Headroom, CodexBar…), and commenters already call this the vibe-coding 'hello world'.

> "Seeing the unused weekly limit for codex and the clock ticking down" ([HN comment, energy123, 'Token anxiety, a slot machine by any other name', 2026-02-17](https://news.ycombinator.com/item?id=47044729))

> "if you have a coding plan with time based limits they there is pressure to make maximum use of it" ([HN comment, Havoc, Token anxiety thread, 2026-02-17](https://news.ycombinator.com/item?id=47042379))

**Steer and approve from anywhere (phone, remote), with heavy trust and reliability caveats** (Hacker News)

There is strong interest in leaving the desk while agents keep working: Anthropic's own Remote Control got 544 points and 313 comments, and Omnara got 310 and 147 points (as of 2026-11-18). Users complain about approving blind on a phone, dropped sessions, thumb-typing, missing E2EE, and opening a remote door into their machine. Many say SSH, mosh and tmux, or the first-party apps, already cover it. Some see a pager/on-call dystopia.

> "Claude Code Remote Control (544 points, 313 comments as of 2026-11-18)" ([HN story, 2026-02-25](https://news.ycombinator.com/item?id=47148454))

> "It's ridiculous to be forced to sit in front of a computer to work with AI." ([HN comment, zomglings, Launch HN: Omnara, 2026-02-12](https://news.ycombinator.com/item?id=46991658))

**Gamifying token usage (leaderboards, 'Strava for Claude Code') draws backlash; habit and progress framing is tolerated** (Hacker News)

Token-usage leaderboards (Straude, CostHawk, claudeusage.com, CCClub) get modest upvotes and pointed criticism: they reward burning money, not progress, and they raise privacy concerns. The 2026 'tokenmaxxing' wave of corporate token leaderboards (Amazon, Meta, Microsoft, Uber) produced big HN threads, with 251 points on Amazon and 293 on Uber as of 2026-11-18. Those threads condemn usage as a metric (Goodhart's law). Defenders frame it as a habit tracker or contribution graph, or want private and team-scoped boards. Year-end 'Wrapped' recaps exist but get low engagement, and Anthropic shipped its own Claude Wrapped.

> "Gamifying Claude Code? Why? A leaderboard of who can can blow the most tokens/money?" ([HN comment, nusl, Show HN: Strava for Claude Code, 2026-02-18](https://news.ycombinator.com/item?id=47065425))

> "AI output in our work should be measured in engineering progress, not in use metrics, right?" ([HN comment, maxverse, Strava for Claude Code, 2026-02-18](https://news.ycombinator.com/item?id=47065425))

**Compulsion, slot machine and burnout: a motivation layer can make it worse** (Hacker News)

There is a persistent HN thread of AI coding as a variable-reward 'slot machine', 'one more turn' compulsion, token anxiety, and burnout from always-on agents. A minority reports genuine flow states. This affects motivation and gamification products directly: streaks and 'keep it busy' nudges could read as exploiting the compulsion. Wellbeing-aware design (breaks, stop points, value over volume) is an open angle.

> "It hits the exact same endorphin system as "one more turn" style games like Civ." ([HN comment, chatmasta, Ask HN: experimenting with LLMs, 2026-07-03](https://news.ycombinator.com/item?id=48781406))

> "being hooked on a slot machine which pays out 95% of the time" ([HN comment, presbyterian, Token anxiety thread, 2026-02-16](https://news.ycombinator.com/item?id=47039426))

**Not noticing when the agent is waiting or done (the alt-tab and babysitting loop)** (Reddit)

This is the pain people describe most. They hand off a task, switch away, then either check back over and over or come back to find the agent has been stuck on a question for an hour. It drives most of the DIY builds: menu-bar monitors, sound mods, phone calls, desk lights, pets. The same request shows up in GitHub issues for Claude Code, Codex, Gemini CLI and Cursor. Two details matter for anyone building here. First, the 'waiting for input' state (idle_prompt) is often missed even when 'done' is caught. Second, no event fires when the user answers, so a status display gets stuck showing the old state.

> "Paranoidly switch back every 30 seconds to check if it's done ... Realize I'm wasting more time checking than actually working" ([r/macapps, OP (menu bar monitor), score 50 as recorded in archive, 2025-09-22](https://www.reddit.com/r/macapps/comments/1nnrfzv/got_tired_of_constantly_checking_if_claude_code/))

> "I kept leaving long Claude Code runs going and coming back to find them stuck on a question for an hour." ([r/ClaudeCode, OP of agentring, score 466, 2026-10-28](https://www.reddit.com/r/ClaudeCode/comments/1xhvnjw/my_claude_code_now_calls_my_phone_when_it_needs/))

**Usage limits and token burn: wanting to see it, and anxiety about it** (Reddit)

Usage is the loudest topic overall on r/ClaudeCode, and in Nov 2026 one user asked for a usage megathread because so many posts were about it. People want a visible, trustworthy meter. They also want history ('which command ate my quota') because they feel drain they can't prove, and Cursor users report sudden jumps. The top-voted hardware posts are usage meters (Clawdmeter: 1674). There is a clear split. Many love an always-on meter, while others say it feeds 'usage anxiety', or that the numbers are already in /usage and the status line.

> "At this point Anthropic should just mail these to us for free" ([r/ClaudeCode, u/mobcat_40 (379) on Clawdmeter ESP32 usage meter, post score 1674, 2026-05-12](https://www.reddit.com/r/ClaudeCode/comments/1takxpl/clawdmeter_a_small_esp32_usage_limit_monitor/))

> "It would be cool if it also could display a chart of the history, I’d like to see how each command affected the usage. I feel like my usage runs out way faster these days but I can’t really prove it." ([r/ClaudeCode, u/Middle-Nerve1732, 2026-05-12](https://www.reddit.com/r/ClaudeCode/comments/1takxpl/clawdmeter_a_small_esp32_usage_limit_monitor/))

**Juggling several parallel sessions: overload and 'which one needs me?'** (Reddit)

Heavy users run 4 to 15 sessions, often across Claude Code, Codex and Gemini. Threads asking how to manage this without 'losing your mind' draw 50 to 250 comments. The answers are scattered: herdr, Orca, tmux, iTerm windows, even paper. Many say 2 or 3 sessions is their real cognitive limit, and that the bottleneck has moved to review. Session-manager posts get upvotes but also 'there are so many of these' fatigue.

> "How do you actually manage multiple parallel Claude Code sessions without losing your mind?" ([r/ClaudeCode post title, 100 comments, 2026-08-12](https://www.reddit.com/r/ClaudeCode/comments/1vm8u30/))

> "I feel like I have to babysit everything." ([r/ClaudeCode post title (runs 4-5 sessions), 2026-10-08](https://www.reddit.com/r/ClaudeCode/comments/1x0r5v3/))

**Glanceable ambient status per session (lights, keys, small screens) with one-press jump** (Reddit)

When people do build hardware or ambient UI, what they ask for is one indicator per agent: running, waiting on me, done, error. Pressing it should focus that session. Single-lamp builds are very popular, yet the top replies immediately ask 'what about multiple sessions?'. Builders say live session state is rarer than usage meters.

> "I do wonder the best light indicator to have if you do run multiple sessions 🤔" ([r/ClaudeAI, u/24props on the desk-lamp status indicator, post score 1637, 2026-05-05](https://www.reddit.com/r/ClaudeAI/comments/1t4gfc7/turned_a_desk_lamp_into_a_claude_code_status/))

> "Each key lights up based on a session, and when one has a question or permission prompt, key goes red. Press the key and VSCode comes into focus." ([r/ClaudeAI, u/GoldAny8608, 2026-05-05](https://www.reddit.com/r/ClaudeAI/comments/1t4gfc7/turned_a_desk_lamp_into_a_claude_code_status/))

**Approving and steering from elsewhere (phone, remote control)** (Reddit)

Remote Control is now the default answer, and people praise it a lot (625-point 'life changing' thread). Complaints are about reliability, not being able to start new sessions remotely, prompts that don't show up, and that reviewing diffs on a phone is hard. A strong minority warn about always-on work creep. A phone-call escalation tool got 466 upvotes, but replies said the native push in RC is enough and that 'development is too visual' for voice.

> "If you are not using /remote-control you need to start using it now. It will be life changing." ([r/ClaudeCode OP, score 625, 261 comments, 2026-05-22](https://www.reddit.com/r/ClaudeCode/comments/1tkv87g/remotecontrol_is_a_window_into_what_the_future_is/))

> "Tried it, works great, but I don't want to work all the time. Don't forget to live buddy" ([r/ClaudeCode, u/Annual_Manner_8654 (top comment, 505), 2026-05-22](https://www.reddit.com/r/ClaudeCode/comments/1tkv87g/remotecontrol_is_a_window_into_what_the_future_is/))

**Focus and drift during the wait** (Reddit)

The wait between prompts is too long to stay focused and too short to do real work. People drift to TikTok, X or HN, and some lose flow for 15 minutes. Workarounds include parallel sessions, exercise between prompts, microtask feeders, and novelty 'waiting' toys. A plugin that matches you with a stranger who is also waiting got 983 upvotes. Others push back that you shouldn't fill every gap.

> "How do you guys stay in a flow state while waiting for Claude?" ([r/ClaudeCode post title, score 307, 248 comments, 2026-08-10](https://www.reddit.com/r/ClaudeCode/comments/1vkwiuw/))

> "I do dead hangs and push ups between Claude prompts in auto mode" ([r/ClaudeCode, u/burntpm, 2026-08-10](https://www.reddit.com/r/ClaudeCode/comments/1vkwiuw/))

**Desk hardware for agents: huge upvotes, DIY culture, price skepticism** (Reddit)

Desk gadgets are among the most upvoted posts in these subs: a usage meter (1674), a desk lamp (1637), the VibeKeys keyboard (1010), a status display (411), a touch strip (389), and a 'Lump' creature (244). The crowd assumes they can build it themselves with Claude for $10 to $40. Commercial units get called out ('flashed M5Stack for 10x the price'), and so do subscriptions. Comments ask for finish and polish (cable at the back, one-click setup). Dedicated keypads like Codex Micro draw 'I just use my keyboard' replies, plus DIY clones from people who can't afford it.

> "Agreed, what am I paying every month for and still no hardware device!!" ([r/ClaudeCode, u/LookAtMyKeyboard (Clawdmeter maker), 2026-05-12](https://www.reddit.com/r/ClaudeCode/comments/1takxpl/clawdmeter_a_small_esp32_usage_limit_monitor/))

> "I actually built the vibe coding keyboard. It's not a meme." ([r/ClaudeCode post title (VibeKeys), score 1010, 2026-05-28](https://www.reddit.com/r/ClaudeCode/comments/1tq5odl/))

**Counter-signal: 'it's already native' and 'how many of these does the world need?'** (Reddit)

Every category draws pushback. Notifications are native, and Remote Control has push. Usage is visible in /usage and the status line. Session managers and usage displays are now the 'hello world' of Claude projects. For a new entrant this means bare notifications, usage meters and session lists are crowded, low-value features unless they offer something clearly new: multi-agent, multi-session glance plus action, history and insight, or real craft and character.

> "I truly do not understand why people here are so obsessed with building usage trackers. The usage stats aren't ever hidden and are always easy to access." ([r/ClaudeCode, u/SPEDpunk, 2026-10-22](https://www.reddit.com/r/ClaudeCode/comments/1xck2ei/claude_now_lives_on_my_phone_home_screen_and/))

> "a claude usage statusbar is the new "hello world"" ([r/ClaudeAI, u/gphie (59), 2026-06-28](https://www.reddit.com/r/ClaudeAI/comments/1ui85ys/i_built_a_claude_statusbar_hardware_display_for/))

## Seen on Reddit

47 posts the research cited, with score and comment count from the Arctic Shift Reddit archive (scores as archived; live Reddit may be higher). "Built" means someone showing what they made; "Talk" is a discussion.

Of the 25 show-and-tell posts, the top two are physical: an ESP32 limit meter (1,674) and a desk lamp used as a status light (1,637).

| Score | Comments | Kind | Post | Posted |
|--:|--:|---|---|---|
| 1,674 | 74 | Built | [Clawdmeter - a small ESP32 usage limit monitor (source code in description)](https://www.reddit.com/r/ClaudeCode/comments/1takxpl/) r/ClaudeCode | 2026-05-12 |
| 1,637 | 90 | Built | [Turned a desk lamp into a Claude Code status indicator](https://www.reddit.com/r/ClaudeAI/comments/1t4gfc7/) r/ClaudeAI | 2026-05-05 |
| 1,160 | 245 | Talk | [I said “H” and it used 26% of the daily usage on the new fable🤣🤣](https://www.reddit.com/r/ClaudeCode/comments/1xs5kde/) r/ClaudeCode | 2026-11-09 |
| 1,010 | 64 | Built | [I actually built the vibe coding keyboard. It's not a meme.](https://www.reddit.com/r/ClaudeCode/comments/1tq5odl/) r/ClaudeCode | 2026-05-28 |
| 983 | 62 | Built | [Waiting Room: A Claude-Code plugin to let u wait with a stranger who is also waiting for their Claude](https://www.reddit.com/r/ClaudeCode/comments/1waef2c/) r/ClaudeCode | 2026-09-08 |
| 894 | 167 | Built | [I coded terminal manager for ADHD brains.  100% Opensource.](https://www.reddit.com/r/ClaudeCode/comments/1vj5ktu/) r/ClaudeCode | 2026-08-08 |
| 625 | 261 | Talk | [/remote-control is a window into what the future is going to be like](https://www.reddit.com/r/ClaudeCode/comments/1tkv87g/) r/ClaudeCode | 2026-05-22 |
| 466 | 77 | Built | [My Claude Code now calls my phone when it needs me. No Twilio, no phone number, free](https://www.reddit.com/r/ClaudeCode/comments/1xhvnjw/) r/ClaudeCode | 2026-10-28 |
| 411 | 41 | Built | [I built a Claude statusbar hardware display for my desk](https://www.reddit.com/r/ClaudeAI/comments/1ui85ys/) r/ClaudeAI | 2026-06-28 |
| 389 | 32 | Built | [Built a little touchscreen dashboard for my desk with Claude Code](https://www.reddit.com/r/ClaudeAI/comments/1xoxnhp/) r/ClaudeAI | 2026-11-05 |
| 317 | 182 | Talk | [This guy consumed $50,000 in 30 days on a $200 subscription and is bragging about it](https://www.reddit.com/r/Anthropic/comments/1mqs5rf/) r/Anthropic | 2025-08-15 |
| 307 | 248 | Talk | [How do you guys stay in a flow state while waiting for Claude?](https://www.reddit.com/r/ClaudeCode/comments/1vkwiuw/) r/ClaudeCode | 2026-08-10 |
| 306 | 110 | Talk | [Claude Code makes me 10x more productive, but mentally exhausted. Anyone else?](https://www.reddit.com/r/ClaudeCode/comments/1xn1urm/) r/ClaudeCode | 2026-11-03 |
| 306 | 86 | Built | [Fav Desk Gadget: Claude Code Usage Display, codeMeter](https://www.reddit.com/r/ClaudeAI/comments/1tmo1sz/) r/ClaudeAI | 2026-05-24 |
| 244 | 55 | Built | [I built "Lump," a quirky desk creature who shows me what Claude is doing, so I don't miss anything](https://www.reddit.com/r/ClaudeAI/comments/1xumt47/) r/ClaudeAI | 2026-11-12 |
| 179 | 27 | Built | [Claude Code limits in a desktop pet](https://www.reddit.com/r/ClaudeAI/comments/1xveugv/) r/ClaudeAI ← the post that started this | 2026-11-13 |
| 172 | 126 | Talk | [The most boring part of my job now is waiting for AI to spit out code](https://www.reddit.com/r/ClaudeCode/comments/1xgvsoh/) r/ClaudeCode | 2026-10-27 |
| 157 | 46 | Talk | [I used to be a hard-core gamer. Vibe coding fuels the same dopamine, but without the existential dread.](https://www.reddit.com/r/vibecoding/comments/1uh6ohg/) r/vibecoding | 2026-06-27 |
| 142 | 60 | Talk | [Why AI coding tools accidentally feel perfect for inattentive ADHD brains](https://www.reddit.com/r/ClaudeCode/comments/1qeb6od/) r/ClaudeCode | 2026-01-16 |
| 135 | 35 | Built | [Turning claude thinking time into productive microtasks](https://www.reddit.com/r/ClaudeCode/comments/1r255kz/) r/ClaudeCode | 2026-02-11 |
| 122 | 79 | Talk | [They removed the buddy from latest? (Claude Code v2.1.97)](https://www.reddit.com/r/ClaudeAI/comments/1sgcbcj/) r/ClaudeAI | 2026-04-09 |
| 99 | 50 | Built | [I built a 3D office where every Claude Code session I run is a little person at a desk](https://www.reddit.com/r/ClaudeCode/comments/1xmym86/) r/ClaudeCode | 2026-11-03 |
| 94 | 28 | Built | [I built a pixel pet that eats your Claude Code tokens (and warns you before the 5h wall)](https://www.reddit.com/r/ClaudeCode/comments/1vy5fcr/) r/ClaudeCode | 2026-08-25 |
| 86 | 151 | Talk | [Claude Code’s $100/month plan — 73% of my weekly limit gone in 2 days](https://www.reddit.com/r/ClaudeCode/comments/1xhfch4/) r/ClaudeCode | 2026-10-28 |
| 78 | 24 | Built | [claude now lives on my phone home screen and tells me how much of my limit is left](https://www.reddit.com/r/ClaudeCode/comments/1xck2ei/) r/ClaudeCode | 2026-10-22 |
| 68 | 10 | Built | [I put my coding agents on my keyboard's RGB F-row: a glance shows who's running, waiting, or done, and one key…](https://www.reddit.com/r/ClaudeCode/comments/1vszoh7/) r/ClaudeCode | 2026-08-19 |
| 60 | 38 | Talk | [I'm starting to think they pushed some update early this month which is blowing up my usage numbers](https://www.reddit.com/r/cursor/comments/1wkr3d8/) r/cursor | 2026-09-19 |
| 58 | 47 | Talk | [For the Love of God, Let us/Claude start sessions from Remote Control](https://www.reddit.com/r/ClaudeCode/comments/1xcsrss/) r/ClaudeCode | 2026-10-22 |
| 50 | 15 | Built | [Got tired of constantly checking if Claude Code finished, so I built this menu bar monitor](https://www.reddit.com/r/macapps/comments/1nnrfzv/) r/macapps | 2025-09-22 |
| 37 | 15 | Built | [Made a $10 desk light that tells me when my AI agent is waiting on me](https://www.reddit.com/r/ClaudeCode/comments/1uiucd1/) r/ClaudeCode | 2026-06-29 |
| 37 | 79 | Talk | [Claude Code needs real remote control from mobile](https://www.reddit.com/r/ClaudeCode/comments/1thyrr2/) r/ClaudeCode | 2026-05-19 |
| 36 | 64 | Talk | [Best mac app / dashboard for managing multiple agents and projects](https://www.reddit.com/r/ClaudeCode/comments/1wsfm2w/) r/ClaudeCode | 2026-09-28 |
| 34 | 20 | Built | [I never know if my overnight Claude Code runs are stuck or just thinking, so I built a desk screen that shows …](https://www.reddit.com/r/ClaudeCode/comments/1u3ffo4/) r/ClaudeCode | 2026-06-11 |
| 34 | 100 | Talk | [How do you actually manage multiple parallel Claude Code sessions without losing your mind?](https://www.reddit.com/r/ClaudeCode/comments/1vm8u30/) r/ClaudeCode | 2026-08-12 |
| 33 | 9 | Talk | [They killed my buddy](https://www.reddit.com/r/ClaudeCode/comments/1smsk3i/) r/ClaudeCode | 2026-04-16 |
| 27 | 43 | Talk | [40% of weekly usage stolen in 1 second](https://www.reddit.com/r/cursor/comments/1xkubzj/) r/cursor | 2026-11-01 |
| 23 | 17 | Talk | [My Claude Code Wrapped is making me question some life choices](https://www.reddit.com/r/ClaudeCode/comments/1px9u9e/) r/ClaudeCode | 2025-12-27 |
| 20 | 21 | Built | [I built a CLI leaderboard to see which of my friends is burning the most on Claude Code (Open Source)](https://www.reddit.com/r/ClaudeCode/comments/1r66oqo/) r/ClaudeCode | 2026-02-16 |
| 16 | 17 | Built | [attention-sound: A Claude Code mod that plays a sound when Claude needs you, so you can do other things while …](https://www.reddit.com/r/ClaudeCode/comments/1x50xme/) r/ClaudeCode | 2026-10-13 |
| 13 | 40 | Talk | [Just curious when U vibe coding and waiting for AI response, what do you normal do?](https://www.reddit.com/r/vibecoding/comments/1t1ev3l/) r/vibecoding | 2026-05-02 |
| 11 | 50 | Talk | [How are u managing running several parallel sessions? I feel like I have to babysit everything.](https://www.reddit.com/r/ClaudeCode/comments/1x0r5v3/) r/ClaudeCode | 2026-10-08 |
| 7 | 8 | Built | [I made a robot that shows limits](https://www.reddit.com/r/OpenaiCodex/comments/1vge47k/) r/OpenaiCodex | 2026-08-05 |
| 6 | 6 | Built | [Session pet : a menu-bar pet that shows which claude code sessions need your attention - Free](https://www.reddit.com/r/ClaudeCode/comments/1v80vcr/) r/ClaudeCode | 2026-07-27 |
| 6 | 9 | Built | [Reboot-surviving remote-control server Claude sessions](https://www.reddit.com/r/ClaudeCode/comments/1wad7fl/) r/ClaudeCode | 2026-09-08 |
| 5 | 1 | Talk | [Feature request: enable ctrl+c interrupt on remote control](https://www.reddit.com/r/ClaudeCode/comments/1tigkw5/) r/ClaudeCode | 2026-05-20 |
| 1 | 1 | Built | [I can't afford Codex Micro, so I turned my Stream Deck into a control panel for AI coding with better feature](https://www.reddit.com/r/ClaudeCode/comments/1xqdnu9/) r/ClaudeCode | 2026-11-07 |
| 0 | 12 | Talk | [Would this be better than codex micro?](https://www.reddit.com/r/ClaudeCode/comments/1v7qri2/) r/ClaudeCode | 2026-07-27 |

## Pricing benchmarks

| Segment | Range | Examples |
|---|---|---|
| Software pets and companions | $0 (most) to $19.99 one-time | Clawd on Desk: free, AGPL-3.0; Pixel Agents: free, MIT; Vibe Island: $19.99 one-time, $10 per extra Mac; Fetch: $19.99 one-time |
| Usage and cost monitors | $0 to $9 one-time | ccusage: free, MIT; CodexBar: free, MIT; Usagebar: $9 one-time, with a free tier |
| Remote control and hosted agent apps | Free self-hosted, hosted from EUR 7 a month | CloudCLI: free self-hosted; CloudCLI Cloud: EUR 7 a month (Hobby), EUR 20 (Growth) |
| DIY boards (software free) | About $21 to $70 for the hardware | Hardware Buddy: M5StickC Plus, about $30; Clawdmeter: Waveshare board, $29.99 to $31.99; Divoom hack: needs a $69.99 MiniToo |
| Finished small status displays | $49 to $115 | Vibe Buddy: $49 preorder; FreakStudio ClaudeAssistant: $70; Token Monitor: EUR 99, about $115 (campaign failed) |
| Agent keypads and controllers | $39 to $230 | VibeKeys: $39, $49 or $99; Ulanzi AU05: $59.99; CtrlVibe: from $109 super early bird; Codex Micro: $230, sold out |
| Premium display plus controller | $169 to $249, plus optional paid plans | SlashVibe: $169 Day 1 (sold out), $189 early bird, $249 retail; SlashVibe software: free plan, paid plans raise voice limits |
| Platform built-ins | No extra charge on top of the plan | Claude Code: needs a paid plan or API billing; Remote Control: Pro, Max, Ultra, Team, Enterprise; Codex pets: no extra charge on ChatGPT plans |

## Questions to settle

- Who uses Burnbot today, and do they come back? The data has no traction figures for it.
- How often are the moments right? Measure false alarms for red to green, going round and drifted.
- Do the burn levels and the fire feel like encouragement or pressure? Test a progress framing with real users.
- Should Burnbot keep refusing to approve from the device? 11 of 27 T1 products do it, including Anthropic's own Hardware Buddy.
- Which hardware path: stay DIY over USB, speak Hardware Buddy's BLE protocol, run on SlashVibe or Stream Deck, or sell a kit?
- Is Codex the right second agent, and when? Lock-in is the top objection, but Codex puts Burnbot up against Clawd on Desk and OpenAI's own pets.
- Would the missing products change the picture? The data lacks first-party features from Windows 11, Zed, Windsurf, Devin, Amp and Factory, plus paid notch apps, most dictation apps and agent-deck.

## How this was made

24 search runs across crowdfunding sites, maker sites, GitHub, Product Hunt, Hacker News, Reddit, press, non-English sources and platform docs turned up 1,858 mentions. Merging duplicates left 1,752 products (25 dropped as out of scope). The 38 that matter most (every crowdfunded or sold device, the biggest pets and limit monitors, and the ones the team named) were profiled from their own pages against the same 20-point checklist. A second researcher then tried to disprove each record and made 548 corrections. 18 adjacent gadgets and platform features got a short profile. A completeness review searched for gaps and re-checked weak claims. Finally, 13 headline claims were checked again by agents told to refute them; all held, four with small corrections. The write-up was then rewritten from the corrected data and fact-checked against it. Searching stopped after two rounds to save usage while some lanes were still finding new things, so the long tail of hobby projects is not complete.

Prices, backer counts and star counts move. Each is as of the date in its source note in `products.json`.

### The headline claims, checked a second time

| Result | Claim | Note |
|---|---|---|
| Confirmed | SlashVibe V1's Kickstarter had raised about $143,175 from 639 backers (goal $10,000) as of 2026-11-18. Early Bird pledge $189, stated retail $249, first batch expected to ship March 2027. It supports 20+ coding agents and approves agent requests on the device. |  |
| Confirmed | Codex Micro is a Work Louder x OpenAI macro pad sold for $230 through OpenAI Supply Co. and Work Louder. Orders opened 2026-07-15 as a limited run and it sold out in about 12 hours; OpenAI has no plans to restock. It has keys to approve agent requests and a voice/dictation key. |  |
| Confirmed | Clawd on Desk (github.com/rullerzhou-afk/clawd-on-desk) is a free AGPL-3.0 desktop pet for Windows, macOS and Linux with about 6,777 GitHub stars as of 2026-11-18. It supports about 30 coding agents (Claude Code, Codex CLI, Copilot CLI, Gemini CLI, Cursor Agent and more), shows permission/approval bubbles, and releases roughly every one to two weeks (v1.6.0 on 2026-11-08). |  |
| Confirmed | Anthropic's claude-desktop-buddy repo (github.com/anthropics/claude-desktop-buddy) is MIT-licensed with about 2,721 stars and 474 forks as of 2026-11-18. It documents a Bluetooth LE 'Hardware Buddy' API in the Claude desktop app (developer mode) and reference ESP32 firmware for an M5StickC Plus (about $30) that shows session state and can approve or deny permission prompts. |  |
| Mostly | Claude Code itself (first-party, free) now has: /stats with an activity heatmap and streaks, /insights which writes an HTML report on how you work, /recap which gives a one-line session summary, and a status line that receives live 5-hour and weekly rate-limit data. Remote Control sends push alerts to a phone. | Every feature is real and documented in first-party docs. The verdict is partly, not confirmed, for four reasons. (1) "Free" is misleading. Claude Code bills by tokens or needs a paid Claude plan. The features cost nothing extra, but /insights uses tokens against your plan or API usage. (2) /stats is no longer its own command. Since v2.1.118 (Apr 23, 2026) it is an alias that opens the Stats tab of /usage. (3) The status line rate-limit fields reach only Pro, Max and Ultra subscribers (or users behind a Claude apps gateway), and only after the first API response. API-key users get none, and the docs list no Team or Enterprise access. (4) Remote Control push needs a Pro, Max, Ultra, Team or Enterprise plan, the Claude mobile app, and opting in under /config. On Team and Enterprise, an Owner must also turn Remote Control on. The heatmap is confirmed by a changelog fix dated Aug 25, 2026. Streaks are confirmed by the Dec 10, 2025 changelog entry ("usage streak"), and I found no later note removing them. I did not see the current Stats tab UI directly: the locally installed CLI is v2.1.4, too old to check. |
| Confirmed | Claude Code once shipped a /buddy companion pet that was later removed. GitHub issue anthropics/claude-code#45596 'Bring Back Buddy' has about 1,197 thumbs-up reactions, and some users pinned version 2.1.96 to keep /buddy. |  |
| Mostly | Pixel Agents (github.com/pablodelucca/pixel-agents) is a free MIT pixel-art office for Claude Code agents inside VS Code, with about 10.3k GitHub stars and about 98,475 VS Code Marketplace installs as of 2026-11-18. It supports Claude Code only, and its roadmap mentions future scores or game elements. | Every stated part of the claim holds. The verdict is partly only because one detail is missing. Stars: 10,286 by the GitHub API, which matches "about 10.3k". Installs: 98,492 on the Marketplace against 98,475 claimed, a 0.02% difference. The MIT license, free price, Claude Code-only support and the roadmap's game and score elements are all confirmed in the README. The missing detail is that it no longer runs only inside VS Code. A standalone CLI (`npx pixel-agents`, needs Node.js 20+) serves the same office in a browser, and the extension is also on Open VSX. The roadmap also names other agents (Codex, Gemini, Cursor), not just game elements. The Marketplace rating is about 4.5 stars from 6 ratings. The install figure and the 1.6.0 version are as reported by the page fetch. No exact last-updated date was shown on the listing, and the repo was last pushed on 2026-11-10. |
| Mostly | CodexBar (github.com/steipete/CodexBar) is a free MIT macOS menu bar app showing usage and limits for Codex, Claude Code and many other providers (about 80), with about 23.2k GitHub stars as of 2026-11-18. | Stars hold: the API showed 23,213 today against the claimed ~23.2k. MIT is confirmed in the API, the README badge and the site footer. "Free" is confirmed by the site ("Free & open source") and no paid tier is listed. Codex and Claude Code are both listed providers. The provider count is out of date: 80 was right per RuntimeWire on 2026-09-23. Today the README banner and codexbar.app both say 114, and a count of the README provider list gives 114 entries (88 in the main list plus 26 generated additions). The app is no longer macOS-only: there is now a Qt 6 Linux desktop app and macOS/Linux CLI tarballs. The latest release is v0.84.0, published 2026-11-07, and the last push was 2026-11-14. |
| Confirmed | Other coding-agent hardware campaigns raised little: CtrlVibe raised HK$80,514 (about US$10,261) from 59 backers, ending 2026-09-13; AgentDeck had CA$597 of a CA$71,000 goal from 3 backers with the campaign running to 2026-12-01; Token Monitor (Fractal Manifold) raised EUR 1,153 of a EUR 28,000 goal from 10 backers and was unsuccessful. |  |
| Confirmed | Agent Cat (agentcat.app) is a free Mac/Windows menu-bar cat for Claude Code, Codex and other agents. Former Pro features became free in v26.35.0 (2026-08-26). It shows usage and limits, has an AI 'Reflect' recap that runs through the user's own Claude CLI, streak pins, and phone/watch apps. The site counter showed about 9,766 downloads as of 2026-11-18. |  |
| Confirmed | CodeBurn is a free MIT usage/cost tracker for AI coding agents with about 11,859 GitHub stars as of 2026-11-18, and it detects looping tool calls and repeatedly failing commands. |  |
| Confirmed | Usagebar (usagebar.com) costs $9 one-time for Mac. Vibe Buddy (vibebuddy.sh) is US$49 with a refundable US$5 deposit and expected shipping around November 2026. VibeKeys Pro is $39 on vibekeys.dev. Vibe Island costs $19.99 one-time for one Mac. FreakStudio's ClaudeAssistant is US$70 on Tindie. |  |
| Mostly | Clauddy (github.com/renatoaug/claude-usage-monitor, npm 'clauddy') is a free MIT pixel-art desktop pet in Rust (egui) for macOS, Windows and Linux that shows Claude Code session and weekly limit percentages, also supports Codex and Cursor, catches fire at 90%+ usage, and had about 125 GitHub stars as of 2026-11-18. It was shown on r/ClaudeAI on 2026-11-13 as 'Claude Code limits in a desktop pet'. | I checked every product detail against primary sources: the GitHub README, design docs, the GitHub API and the npm registry. These hold: MIT license, Rust/egui, macOS, Windows and Linux, session and weekly %, Codex and Cursor, and 125 stars as of 2026-11-18, an exact match. Two refinements. First, fire is tied to session usage passing a configurable threshold that defaults to 90%. Second, the npm package is only a launcher for the native app. The GitHub About line still says "for macOS", but the README lists all three platforms. I could not verify the r/ClaudeAI post (date and title). WebFetch cannot reach reddit.com, and permission was denied for the Reddit JSON search API and a Redlib mirror. promppy.com's /topic/claude-code page, /topic/claude page and RSS feed show no Clauddy item. Web searches for the post title and for 'Clauddy' returned nothing. Nothing contradicts the Reddit detail, but it is unconfirmed, so the verdict is partly rather than confirmed. Added after the check: the Arctic Shift Reddit archive shows the post went up on 2026-11-13 (not 11-18), by u/SuccessfulCress7441, with 179 points and 27 comments as archived. |

### What this research does not cover well

- Platform features from several major vendors are missing, and the platform round 2 was skipped. No first-party features appear from Microsoft beyond the Copilot key: Windows 11 announced agents on the taskbar, with status badges and hover cards for running agents, which is OS-level agent state that is always on screen. Nothing appears from Cognition (Windsurf Cascade completion notifications, Devin's desktop, mobile and Slack status), Zed (agent panel notifications and sound when a thread finishes or needs approval), Amp (thread sharing and any social or leaderboard features), or Factory (Droid desktop and mobile apps). macOS Tahoe Live Activities is listed, so leaving out the Windows equivalent unbalances the 'first-party will Sherlock this' analysis.
- The adjacent round 2 was skipped, and the commercial general-purpose shells that people repurpose for agent status are missing. That includes paid notch apps (NotchNook, Alcove, DynamicLake), the Corsair Xeneon Edge widget touchscreen, RunCat, mute and busy buttons (MuteMe, Embrava Blynclight, Nanoleaf), and the dictation apps people use as 'voice remotes' for agents (Superwhisper, VoiceInk, Aqua Voice, Willow, MacWhisper). Wispr Flow is the only one of these listed. These are the price anchors behind the 'just use X' objections in the demand data. One T2 orchestrator is also confirmed missing: asheshgoplani/agent-deck, checked on GitHub today. It is a Go and tmux TUI session manager showing working, waiting and done states for Claude Code, Codex, Gemini CLI and OpenCode, with an 'agent-deck web' UI, about 1.3k stars, MIT licence, and more than 4,600 commits.

## Appendix: adjacent gadgets and platform features (T3)

| Name | Maker | What | Price |
|---|---|---|---|
| [Claude Code /usage, /stats, /insights and /recap](https://code.claude.com/docs/en/costs) | Anthropic | Built-in Claude Code usage and reflection tools. /usage (aliases /cost and /stats) shows session cost, plan usage bars, activity stats and an attribution and recommendations breakdown with an 'f to fix' shortcut. /stats opens a Stats tab with an activity heatmap and streaks. /insights writes an HTML report on how you work. /recap gives a one-line session summary. The status line receives live rate-limit data. | Free |
| [Claude Code Channels](https://code.claude.com/docs/en/channels) | Anthropic | A first-party research-preview feature. Channel plugins (MCP servers) push Telegram, Discord or iMessage chats, webhooks and alerts into a running local Claude Code session, and can relay tool-permission prompts so you approve or deny them from your phone. | Free |
| [Claude Code Remote Control and mobile push](https://code.claude.com/docs/en/remote-control) | Anthropic | First-party feature that connects claude.ai/code and the Claude iOS/Android app to a Claude Code session running on your own machine (from the CLI, VS Code or the Desktop app). You start it with 'claude remote-control' (server mode, up to 32 concurrent sessions by default, same-dir or worktree spawn modes, QR code) or with /remote-control (/rc) inside a session. Permission prompts and questions are forwarded to the phone or browser and stay open until you answer. Two /config toggles control mobile push: 'Push when Claude decides' and 'Push when actions required'. Pushes are skipped while you are focused on the terminal, and CLAUDE_CLIENT_PRESENCE_FILE can suppress them whenever you are at the machine. The connection is outbound HTTPS only, and there is an optional Trusted Devices requirement. Related first-party options: Dispatch (send the Desktop app a task from the phone), Channels (Telegram, Discord, iMessage) and cloud sessions. | Free |
| [Claude Code status line](https://code.claude.com/docs/en/statusline) | Anthropic | First-party custom status bar: Claude Code runs any shell command you configure and passes it session JSON on stdin. The JSON includes model.id/display_name, workspace and repo, cost.total_cost_usd (client-side estimate), total_duration_ms, lines added/removed, context_window (input/output tokens, size, used_percentage/remaining_percentage, current_usage), effort.level, prompt_cache stats, session_id/session_name, transcript_path, pr.number/review_state, worktree.*, and rate_limits.five_hour/seven_day used_percentage and resets_at. rate_limits appears only for Pro/Max/Ultra subscribers, or behind a gateway spend limit, and only after the first API response. Updates are event-driven with a 300 ms debounce, plus an optional refreshInterval timer (minimum 1 s). | Free |
| [Claude Code team analytics dashboard](https://code.claude.com/docs/en/analytics) | Anthropic | A first-party admin dashboard. Teams/Enterprise get it at claude.ai/analytics/claude-code: lines accepted, suggestion accept rate, DAU and sessions, GitHub-attributed PRs and lines, a top-10 contributor leaderboard and CSV export. API customers get a version at platform.claude.com/claude-code with per-user spend and lines accepted. | Free |
| [Claude Desktop app, Code tab](https://code.claude.com/docs/en/desktop) | Anthropic | Claude Code inside the Claude desktop app (macOS, Windows, Linux beta). It runs parallel sessions with optional git worktrees, split view, permission modes, a usage ring and context card, OS notifications when a session finishes, and cloud/SSH/Remote Control/Dispatch sessions you can follow from the mobile app. In developer mode it also offers a 'Hardware Buddy' BLE API for maker devices. | Free |
| [Codex app (OpenAI)](https://learn.chatgpt.com/docs/app) | OpenAI | OpenAI's first-party desktop 'command center' for running coding agents in parallel threads, with built-in git worktrees, in-thread diff review, automations and a review queue. It launched on macOS (Apple Silicon) around Feb 2, 2026, and the docs now present it as the ChatGPT desktop app for macOS, Windows and Linux. Turn-completion notifications can be set to never, background-only or always, with separate toggles for permission and question alerts. A sidebar activity bell shows unread, running and waiting chats (Cmd+Option+U). Floating pets show Running, Needs input, Ready or Blocked. A Profile page shows activity insights, lifetime tokens, peak tokens, streaks, longest task and token activity, plus a shareable profile card with usage highlights. | Free |
| [Codex CLI /statusline, /status, /usage](https://developers.openai.com/codex/cli/slash-commands) | OpenAI | Built-in Codex CLI commands. /statusline configures TUI footer items interactively (model plus reasoning, context used, 5-hour and weekly limits, git branch, token counters and more; saved to tui.status_line). /status shows session config and token usage. /usage shows account token activity (daily, weekly, cumulative). /title sets terminal-title fields such as status and task progress. | Free |
| [Codex on mobile](https://learn.chatgpt.com/docs/mobile) | OpenAI | In the ChatGPT mobile app you can start, follow, steer and review Codex tasks running in the cloud or on a paired Mac or Windows PC. It pairs by QR code from the desktop app (Settings > Connections > Control this Mac or PC). On the phone you approve, always-approve, deny or redirect commands, see when input is needed, and inspect diffs. | Free |
| [Codex pets (OpenAI)](https://learn.chatgpt.com/docs/pets) | OpenAI | First-party optional animated pets that show Codex agent state. In the ChatGPT desktop app (macOS and Windows) the pet floats above other windows. It tracks four states across multiple chats (Running, Needs input, Ready, Blocked) and shows the most urgent one first, in this order: Needs input > Blocked > Ready > Running. Terminal pets in the Codex CLI cover a single session and need iTerm2 3.6+, Kitty graphics or Sixel (not inside tmux or Zellij). The web version is limited to an in-chat pet, and the IDE extension has none. You can make custom pets with the bundled 'hatch-pet' skill (stored locally) or upload a 1536x1872 PNG/WebP sprite sheet on the web. | Free |
| [Cursor Agents Window](https://cursor.com/docs/agent/agents-window) | Anysphere (Cursor) | Cursor 3's agent-first workspace, generally available since April 2, 2026. One sidebar runs and lists many parallel local, worktree, remote-SSH and cloud agents, including agents started from web, phone, Slack, GitHub or Linear. Since then Cursor has added an iOS app with lock-screen Live Activities (up to 8 agents), push notifications when an agent finishes a turn, and Remote Control of local agents from the phone (Oct 6, 2026). | Bundled in Cursor; no separate price. Th… |
| [Cursor Team Analytics](https://cursor.com/docs/account/teams/analytics) | Anysphere (Cursor) | Web dashboard for Cursor Team and Enterprise plans. It shows AI share of committed code, agent edits, tab completions, messages, active users, 365-day daily usage, repository insights, cloud-agent usage (agents, PRs, lines) and a Usage Leaderboard that every team member can see. An Admin API (Enterprise only) gives programmatic access. | Included with Cursor Team and Enterprise… |
| [Gemini CLI hooks, notifications, /stats and loop detection](https://geminicli.com/docs/hooks/reference) | Google | First-party Gemini CLI features that overlap with agent companions. (1) Hooks: 11 events (BeforeTool, AfterTool, BeforeAgent, AfterAgent, BeforeModel, BeforeToolSelection, AfterModel, SessionStart, SessionEnd, Notification, PreCompress) exchange JSON over stdin/stdout. BeforeTool can deny or rewrite a call. The Notification hook only observes and cannot approve. (2) Terminal notifications for 'action required' and 'session complete' via OSC 9/OSC 777, falling back to a terminal bell; set with general.enableNotifications, which is experimental and off by default. (3) /stats with session, model (token counts and quota), tools and heatmap views; heatmap shows a calendar of daily token usage across local sessions. (4) Automatic loop detection, on by default (model.disableLoopDetection=false). | Free |
| [GitHub Agent HQ / agents panel](https://github.blog/news-insights/company-news/welcome-home-agents/) | GitHub (Microsoft) | GitHub's 'mission control' for assigning, steering and tracking several coding agents (Copilot, Anthropic Claude, OpenAI Codex and custom agents) across github.com, VS Code, GitHub Mobile and Copilot CLI. It was announced on Oct 28, 2025. Claude and Codex arrived in public preview on Feb 4, 2026 for Copilot Pro+ and Enterprise and were extended to Business and Pro on Feb 26, 2026. You can assign one issue to several agents and compare the results. The agents panel is available from any GitHub page. It lists sessions with logs, token usage and session length, and you can steer Copilot sessions from the web or mobile (steering is not available for third-party agents). | Requires a paid Copilot subscription (Pr… |
| [GitHub Copilot usage metrics and premium request usage](https://docs.github.com/en/copilot/concepts/copilot-usage-metrics/copilot-metrics) | GitHub (Microsoft) | Admin dashboards (usage, code generation by users and agents, impact, repository insights) plus enterprise/org usage-metrics APIs and NDJSON exports. Usage metrics went GA on Feb 27, 2026, and later updates added coding-agent PR metrics (Jul 2026) and VS Code Agents window metrics (Sep 2026). Individuals see quota in IDE status bars and on the billing pages. Since June 1, 2026, Copilot bills in token-based 'GitHub AI Credits' instead of premium requests; only annual Pro/Pro+ subscribers stay on premium-request billing until their plans expire. | Metrics come with Copilot Business ($19/… |
| [Google Antigravity](https://antigravity.google/) | Google | Google's agentic development platform (2.0 announced at I/O on May 19, 2026). It has four parts: the Antigravity App (a 'central command center' that runs many local agents in parallel, with subagents, scheduled cron tasks, voice prompts and JSON hooks), the Antigravity CLI ('agy'; TechCrunch reports it replaces Gemini CLI), an IDE and an SDK. The CLI's /usage panel shows per-model-group quota against a 5-hour and a weekly limit. Remote Control lets you drive desktop and CLI sessions from any browser, answer tool approvals there, and get push notifications through a home-screen web app. | Free |
| [JetBrains Air](https://www.jetbrains.com/air/) | JetBrains | JetBrains' system for running and reviewing multiple coding agents. It started as a standalone macOS app in public preview (March 2026) and now also ships as 'Air in IDEs', a plugin and 2026.3 EAP builds. It has per-project sessions with unread updates and changed files, in-context diff review with line comments sent back to the agent, automations triggered by merges or PRs, and team governance. It supports Claude Agent, Codex, Gemini, GitHub Copilot, Junie and OpenCode, plus any ACP agent. | Free |
| [Xcode 26.3 agentic coding](https://www.apple.com/newsroom/2026/02/xcode-26-point-3-unlocks-the-power-of-agentic-coding/) | Apple | Xcode 26.3 (announced Feb 3, 2026) put Anthropic's Claude Agent and OpenAI's Codex inside Xcode. Agents can search docs, change project settings, run builds and capture Previews to check their own work, and Xcode exposes its capabilities over MCP. Xcode 27 (WWDC, June 8, 2026; now the current version on developer.apple.com) adds Google's agents, Agent Client Protocol support for any ACP agent, plug-ins with custom skills, a /plan mode and agent conversations in editor tabs. | Free |

## Files

- `market-map.html`: the interactive page, built by `build_page.py` from the template.
- `catalogue.csv`: all 1,752 products found, one row each, for a spreadsheet.
- `products.json`: full records, sources and verification for every profiled product, plus the catalogue.
- `analysis.json`: the write-up, demand research and completeness review. `reddit-posts.json`, `spot-check.json`: as named.
- `assemble.py` → `curate.py` → `build_page.py` / `build_report.py`: rebuild everything from the research run.
