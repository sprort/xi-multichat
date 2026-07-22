# MultiChat

[![Latest Release](https://img.shields.io/github/v/release/sprort/xi-multichat?label=download)](https://github.com/sprort/xi-multichat/releases/latest)

An [Ashita v4](https://ashitaxi.com/) addon for HorizonXI that combines LS1, LS2, Party, Tell, Say, and system messages (crafting/fishing, combat, quests/NPC dialogue) into one multi-channel chat window.

**This addon doesn't do anything the game itself doesn't already do natively.** It only reads text that's already visible in your own chat log (or, for Craft/Combat/Quest, text the game client is already about to add to your log) and reorganizes/recolors it into separate tabs for readability. It never sends, blocks, injects, or modifies any packet, message, or game state, and it has no effect on what anyone else sees — see [How chat is captured](#how-chat-is-captured) below for exactly how each channel is read.

This addon should work on any FFXI private server running Ashita v4, but it has only been built and tested against HorizonXI.

**[⬇ Download the latest release](https://github.com/sprort/xi-multichat/releases/latest/download/multichat.zip)** — extract into `Ashita/addons/`, then load with `/addon load multichat`.

## Features

**Channels** — one window, ten tabs, switchable by button with the active one highlighted: LS1, LS2, Party, Tell, Say, Shout/Yell, Craft, Combat, NPC, SYS.

- **Shout/Yell** ("Sh/Y"): combined tab; Shout and Yell colored differently so they stay distinguishable, with a Both/Shout/Yell filter in Settings
- **Craft**: synthesis results and craft/fishing skill-ups, colored by message type
- **Combat**: hits/misses/crits, TP moves, casting, status effects, HP/MP recovery, defeats, skill-ups, item drops/use, experience, level up/down — colored by message type and by who's acting (see [Color reference](#color-reference))
- **NPC**: dialogue (with the speaker's name) and quest/event reward items
- **Tell**: usernames show which direction each tell went -- `>>Abbynightwish` for one you sent, `Abbynightwish>>` for one you received -- matching FFXI's own native convention, so scrolling back through history you can always tell who a message was sent to or came from
- **Party**: also includes emotes ("Kosami nods.") between party/alliance members -- both the person performing the emote and, if it's targeted at someone ("Kosami waves to Sprort."), the target too have to be in your party/alliance. A targeted emote at someone outside it lands in Say instead, the same as any other emote from someone nearby
- **SYS**: general system broadcasts, plus Auction House messages, delivery box messages (claiming AH sale proceeds), the **Checker** and **conquest** addons' results, and the server's own "Conquest update:" broadcast — each labeled by source (System/Auction/Delivery/Checker/Conquest) and colored to match (see [Color reference](#color-reference)). Delivery box messages never alert
- Achievement unlocks and hardcore-character milestones broadcast to *every* tab at once, in a distinct color, since they're notable regardless of which tab is active
- Craft/Combat's "Everyone / Myself" filter and Shout/Yell's "Both / Shout / Yell" filter apply retroactively to history already captured, not just messages received after you change them

**Display**

- Item names highlighted, matching how the native log styles them
- Per-channel colored text/timestamps/brace coloring for LS1/LS2/Party/Tell/Say (other channels use fixed colors)
- Message column aligned to the widest username actually present in that channel
- Resizable split view (side-by-side or stacked) and multi-window pop-out — pop out as many channels at once as you like
- Invert-flashing alert indicator for unseen messages (visual only, no sound)
- Click a line to copy it, or use the right-click menu to copy name/message/line
- Duplicate-message suppression
- 5000-line-per-channel history, backed by a ring buffer so the cap stays cheap regardless of size (the most recent 500 lines are the ones drawn in the window; the full history is still what Copy grabs, keeping the per-frame render cost bounded during heavy combat)
- Stays hidden until you're actually logged into the world (safe for auto-load from `default.txt`)
- Settings persist across sessions

**Settings** (⚙ gear button): whole-window transparency, font size (9–45px), line spacing (0–8px), timestamp format (`HH:MM:SS`/`HH:MM`, 12h/24h), and colors for timestamps/usernames/text — one color for all channels or a different color per channel, with a one-click reset.

## Color reference

Craft/Combat text is colored by message type, not channel: abilities/skills yellow, damage red, healing light blue, status effects purple, item drops white, experience green, level up green, level down light red (not user-configurable). Skill-ups stay ability yellow; skill/character level-ups are both green. Synthesis results are white, matching the native log. Fishing bite/feel messages use the same green/olive/red good/neutral/bad mapping as the approved FishAid addon; the Angler ability's catch reveal is merged into the preceding "Something caught the hook!" line rather than shown separately, since the two always arrive together.

Combat usernames are colored by who they are: you = one shade of blue, party/alliance (including trusts) = a different shade, pets/summons = light green, confirmed enemies = red, other players = white — checked against live entity data, not a name list, so it stays accurate for any mob without upkeep. Pets of *any* kind (your own or a party member's — avatars, elemental spirits, BST jug pets, wyverns, automatons) are told apart from real monsters by their entity-index range rather than by ownership (which the client doesn't expose reliably for other players' pets), so a party member's Garuda or jug pet shows as a pet rather than being mistaken for an enemy, while a same-named notorious monster you actually fight still shows as an enemy.

SYS sub-sources each get their own color: Auction House messages are yellow (username "Auction"); Checker's `/check` results use per-segment coloring matching its own native output (name/conditions cream, arrow/level aqua, brackets purple, verdict tier-colored — username "Checker"); the conquest addon's results use per-nation coloring matching its own output (username "Conquest"); the server's "Conquest update:" broadcast uses SYS's default color (username "System"); achievement unlocks and hardcore-character milestones are a distinct vivid orange, broadcast to every tab (usernames "Achievement"/"Hardcore").

## How chat is captured

Every channel works the same basic way: read data the game already sends to (or is already about to show) your own client, then display it in a tab. Nothing is ever sent, blocked, or altered — this addon reads state, it never writes it.

| Source | Mechanism |
|---|---|
| Incoming LS1/LS2/Party/Tell/Say | Ashita's `packet_in` event, message packet `0x017` |
| Outgoing `/say`, `/tell` | The `command` event — read from what you typed |
| Outgoing LS1/LS2/Party | The outgoing chat packet `0x0B5` via `packet_out` (read-only, never modified) |
| Craft, Combat | `text_in`, matched against known phrasings — same mechanism the approved **FishAid** addon uses for fishing messages |
| NPC dialogue | `text_in`, chat mode 150 — same mode the approved **Balloon** addon uses for its speech bubbles |
| Shout, Yell | `text_in`, chat modes 10/11 |
| SYS (general broadcasts) | `text_in`, chat mode 151 (Balloon's `chat_modes.system`) |
| Party/alliance emotes | `text_in`, chat mode 15 (Balloon's `chat_modes.emote`), routed to Party or Say depending on who's involved -- see below |
| Auction House, delivery box, Checker, conquest, "Conquest update:" | `text_in`, matched by text rather than mode — see below |

A few things worth knowing:

- Craft/Combat's phrase list isn't exhaustive yet — some less common messages may not be categorized on the first pass. Ordinary player chat is excluded from this matching entirely by its chat mode, so a line can't be mistaken for a combat/craft message just because it contains a similar-looking phrase.
- NPC dialogue's "Name : text" split uses the same technique Balloon uses for its own speaker extraction. An unprefixed continuation line (an NPC's own second sentence, not a different speaker) inherits the most recent speaker within the same event instead of falling back to a generic "NPC" label.
- Some custom server NPCs (e.g. HorizonXI's achievement-system NPCs) send their dialogue through the same native Say packet/mode a player's own `/say` uses, rather than the proper NPC dialogue mode. Since a real FFXI player name can only ever be pure letters (no spaces, hyphens, digits, or punctuation), an incoming Say whose sender name isn't is rerouted to NPC instead -- reliable without needing to hardcode specific NPC names.
- Achievement unlocks and hardcore-character milestones are checked *before* any mode-based routing (by text, since they matter regardless of what mode they arrive under), so they get their own broadcast-to-every-tab treatment instead of just showing up in SYS.
- Emotes are matched by their leading word ("Kosami nods.", "You wave." → resolved to your own name), then checked against your current party/alliance roster -- the same technique already used for Combat's username coloring. A targeted emote ("... to Name.") also has its target checked the same way: only lands in Party if *both* the actor and the target are in your party/alliance, otherwise it's routed to Say instead of being dropped. Your own name always occupies a party memory slot even when you're not actually partied at all, so that specific case is checked separately (whether anyone besides you is actually in the party) rather than trusting the roster check alone.
- Auction House, delivery box, **Checker**, and **conquest** are matched by text specifically because mode can't distinguish them: Checker and conquest build their own output via `print()` (no mode at all), and Auction House shares mode 121 with synthesis results. The server's "Conquest update:" broadcast is likewise text-matched (its exact mode isn't confirmed), requiring an exact known nation name before "- \<level\>" so it can't misfire on unrelated chat formatted similarly. Of the Auction House messages, only a sale notification (someone buying something you listed) triggers SYS's normal alert -- your own purchase confirmations, delivery box messages, and the listing/fee messages around them all stay silent.
- FFXI's text is Shift-JIS, not UTF-8, which ImGui doesn't understand on its own — unconverted, every byte renders as its own "?" placeholder regardless of font. Real Japanese text (and Latin-1 accented characters) is converted using the [GdiFonts](https://github.com/ThornyFFXI/gdifonttexture) library (MIT license, bundled under `gdifonts/`), the same technique **Balloon** uses. A handful of individual typographic symbols (curly quotes, stars, etc.) are mapped to plain ASCII instead of their real Unicode codepoints, since even once correctly converted, the loaded font's Japanese glyph range doesn't cover those general symbol/punctuation blocks.

## Commands

- `/multichat` — toggle the main window
- `/multichat show` — force the window open and re-center it
- `/multichat reset` — reset all window positions and re-center
- `/multichat trans <0-100>` — set window background opacity (also available as a slider in the Settings window)
- `/multichat checkupdate` — check GitHub for a newer version without installing it
- `/multichat update` — download and install the latest version, then reload automatically

## Updating

This is the one place MultiChat reaches outside your own client: once per session, right after your character finishes loading into the world, it makes a single HTTPS request to this repo on GitHub to compare versions (same technique the approved **anglin** addon's own updater uses). Nothing is downloaded or changed by this check alone — it only posts a message into SYS (username "MultiChat"), with the tab alert triggering only when a newer version actually exists. Installing an update (`/multichat update`) downloads `multichat.lua`, `README.md`, `LICENSE`, and the `gdifonts/` files fresh from this repo, overwrites the local copies, and reloads the addon automatically — it aborts on the first failed download rather than leaving a partial mix of old and new files. If `socket.ssl.https` isn't available in your Ashita install for some reason, this fails safely and simply does nothing.

## How to Add Support for Japanese Language Fonts

If Japanese (or other CJK) characters show up as `?` in MultiChat, that's expected out of the box — and it's **not something this addon can fix on its own**. Here's why, and how to actually fix it.

**Why this happens:** MultiChat renders through Ashita's ImGui system, which is completely separate from FFXI's own native chat log font. ImGui only draws glyphs that exist in its loaded font atlas, and that atlas is a single, Ashita-wide resource shared by *every* ImGui-based addon — not something an individual addon builds for itself. By default, Ashita loads a font called **Agave**, which doesn't include Japanese glyphs, so any Japanese text renders as `?` placeholders even though the underlying text data is correct (FFXI's native chat log, which has its own separate font system, renders the same text just fine).

**The fix** is a one-time, addon-independent Ashita configuration change:

1. **Download a Japanese-capable font.** [Noto Sans JP](https://fonts.google.com/noto/specimen/Noto+Sans+JP) on Google Fonts is a good free option and is what these instructions assume. Click "Get font" / "Download family" to get a `.zip`.
2. **Extract the zip** and find the **static Regular weight** file — for Noto Sans JP this is `static/NotoSansJP-Regular.ttf`. Use this one specifically; the variable-weight file (e.g. `NotoSansJP-VariableFont_wght.ttf`) isn't well-supported by ImGui's font loader.
3. **Copy that `.ttf` file into `<Ashita install>/resources/fonts/`** (for example, `C:\HorizonXI\Game\resources\fonts\`). Create the `fonts` folder if it doesn't already exist — Ashita only loads fonts from this specific location, not fonts already installed on Windows.
4. **Back up your boot profile**, then edit it. This is the `.ini` file in `<Ashita install>/config/boot/` that you actually launch the game with (for HorizonXI, typically `ashita.ini`) — not the read-only `ashita.xxx.ini` reference files.
5. Find (or add) the `[ashita.imgui.fonts]` section in that file and set it to:
   ```ini
   [ashita.imgui.fonts]
   font0.family = NotoSansJP-Regular.ttf
   font0.size   = 14,18,24,32
   font0.is_jp  = true
   ```
   Keep whatever `font0.size` list your profile already had (or use `18` if you're starting fresh) — just make sure `font0.family` points at the file name you copied in step 3, and `font0.is_jp` is `true`.
6. Save the file and relaunch the game.

**A few things worth knowing:**
- This changes the font for **every** ImGui-based addon at once, not just MultiChat — it's a shared, global setting, not per-addon.
- You won't lose English text. Noto Sans JP includes full Latin glyph coverage on its own, and separately, Ashita's `is_jp = true` flag uses Dear ImGui's built-in Japanese glyph range, which always includes Basic Latin as a baseline.
- Full reference: [Ashita v4 Configurations docs](https://docs.ashitaxi.com/usage/configurations/) (see the `[ashita.imgui.fonts]` section).

## Installation

Download the [latest release](https://github.com/sprort/xi-multichat/releases/latest) (or clone this repo), copy the `multichat` folder into `Ashita/addons/`, then load with `/addon load multichat`.

## Credits

MultiChat's own code is original, but several techniques were verified against other approved HorizonXI addons' source before being independently implemented here, rather than guessed at blind:

- **[Balloon](https://github.com/onimitch/ffxi-balloon-ashitav4)** — the NPC dialogue chat mode (150), Shout/Yell modes (10/11), the SYS chat mode (151), the synth chat mode (121, relevant to Auction House message detection), and the "Name : text" speaker-splitting technique
- **[FishAid](https://github.com/TheAngryRogue/AshitaFishaid)** — the `text_in`-based approach to detecting fishing/craft messages, and the good/neutral/bad color mapping for fishing bite/feel messages
- **[Checker](https://github.com/AshitaXI/Ashita-v4beta/tree/main/addons/checker)** (official first-party Ashita addon, GPL-3.0) — its `/check` results are captured into SYS, colored to match its own difficulty-tier colors (cross-referenced against Ashita's own `chat.lua` color-name table). No Checker code is included here -- only its message format and color-table indices were referenced to independently write MultiChat's own detection/coloring logic, so this carries no GPL obligations for MultiChat itself, unlike GdiFonts below
- **[conquest](https://github.com/AddonsXI/conquest)** (official first-party Ashita addon, GPL-3.0) — its `/conquest` results are captured into SYS, colored to match its own per-nation colors. Same no-code-included reasoning as Checker above
- **[SimpleLog](https://github.com/Spike2D/SimpleLog)** — the live entity-data technique (SpawnFlags/PetTargetIndex) used to tell party/pets/enemies/other players apart for Combat's username coloring
- **[GdiFonts](https://github.com/ThornyFFXI/gdifonttexture)** (ThornyFFXI) — actually bundled under `gdifonts/` (see License below) for Shift-JIS → UTF-8 conversion
- **[anglin](https://github.com/Astika2/FFXI/tree/main/addons)** (Astika) — the in-game update-checking approach (see [Updating](#updating)): fetch the raw file from GitHub and regex the `addon.version` line straight out of it, no separate manifest/API needed. No anglin code is included here, only the technique

## License

MIT — see [LICENSE](LICENSE). `gdifonts/` is a bundled third-party dependency under its own MIT license (ThornyFFXI) — see [gdifonts/LICENSE](gdifonts/LICENSE).
