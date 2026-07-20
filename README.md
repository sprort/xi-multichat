# MultiChat

[![Latest Release](https://img.shields.io/github/v/release/sprort/xi-multichat?label=download)](https://github.com/sprort/xi-multichat/releases/latest)

An [Ashita v4](https://ashitaxi.com/) addon for HorizonXI that combines LS1, LS2, Party, Tell, Say, and system messages (crafting/fishing, combat, quests/NPC dialogue) into one multi-channel chat window.

**This addon doesn't do anything the game itself doesn't already do natively.** It only reads text that's already visible in your own chat log (or, for Craft/Combat/Quest, text the game client is already about to add to your log) and reorganizes/recolors it into separate tabs for readability. It never sends, blocks, injects, or modifies any packet, message, or game state, and it has no effect on what anyone else sees — see [How chat is captured](#how-chat-is-captured) below for exactly how each channel is read.

This addon should work on any FFXI private server running Ashita v4, but it has only been built and tested against HorizonXI.

**[⬇ Download the latest release](https://github.com/sprort/xi-multichat/releases/latest/download/multichat.zip)** — extract into `Ashita/addons/`, then load with `/addon load multichat`.

## Features

- Single window showing LS1 / LS2 / Party / Tell / Say / Shout/Yell / Craft / Combat / NPC / SYS, switchable by channel button, with the active channel highlighted
- **Shout/Yell** tab (button labeled "Sh/Y"): combines both into one tab, colored differently per message (orange for Shout, pink/magenta for Yell) so they stay easy to tell apart; a Settings option lets you show Both, Shout only, or Yell only
- **Craft** tab: synthesis results (NQ/HQ/break) and craft/fishing skill-ups
- **Combat** tab: hits/misses/crits, TP move ready/use, casting, status ailments (paralyze, slow, poison, etc.) and buffs (Shell, Protect, etc.) landing, HP/MP recovery, defeats (both sides), combat skill-ups and skill level-ups, item drops (who found/obtained what) and item use, experience gained, and level up/down
- **NPC** tab: NPC dialogue (with the NPC's name in the username column) and quest/event reward items ("Obtained: X.")
- **SYS** tab: general system messages/broadcasts, detected by chat mode rather than by matching text, colored an easy-to-read light purple, username shown as "System". Always flashes its tab alert on a new message regardless of whether it's currently visible, the same way Tell and Party do -- except Auction House messages (confirmation sequence when placing an item up for auction, listed under username "Auction", colored yellow), which stay silent except for the sale-confirmation message ("Your 'X' has sold..."), which does alert like everything else in SYS
- The official **Checker** addon's `/check` results are also captured into SYS (username "Checker"), colored per-segment to match Checker's own native coloring -- name and conditions in cream, the arrow and level number in aqua, brackets/parens in purple, and the verdict tier-colored (too weak = grey, easy prey = green, even match = coral, tough/very tough/incredibly tough = salmon/tomato, impossible to gauge = magenta)
- The official **conquest** addon's `/conquest` (or `/regions`) results are likewise captured into SYS (username "Conquest"), colored per-nation to match its own coloring (San d'Oria = red, Bastok = blue, Windurst = yellow, Beastmen = lime). The server's own periodic "Conquest update:" broadcast is also captured into SYS under username "System"
- Achievement unlocks and HorizonXI's server-wide "hardcore character" level milestone announcements are broadcast to every tab (not just Craft/Combat/NPC/SYS), colored a distinct vivid orange, since they're significant enough to want visible regardless of which tab is active, shown under username "Achievement" / "Hardcore" respectively
- Craft and Combat each have an "Everyone / Myself" filter in Settings ("Myself" includes your own pets/summons), and Shout/Yell has a "Both / Shout / Yell" filter -- all three apply retroactively to history already captured, not just messages received after you change them
- Craft and Combat text is colored by message type instead of by channel: abilities/skills in yellow, damage in red, healing in light blue, status effects (ailments and buffs landing) in purple, item drops in white, experience gained in green, level up in green, level down in light red (not user-configurable). Incremental skill-ups ("skill rises N points", combat and craft/fishing alike) stay the plain ability yellow -- skill level-ups ("skill reaches level N") and character level-ups are both the same green. Synthesis results (success and lost-material failures) are white to match the native log. Vanishing (teleport/warp/escape, or a defeated mob disappearing) is white since it isn't damage. Fish caught (and giving up on a bite) are white, and fishing bite/feel messages (hook, line pull, "good/bad/terrible feeling", skill checks) are colored green/olive/red to match the native log's own good/neutral/bad signal, using the same color mapping as the approved FishAid addon. The Angler ability's catch reveal ("Your keen angler's senses tell you...") is merged into the "Something caught the hook!" line right before it instead of showing as its own separate line, since the two always arrive together at the same instant
- Combat usernames are colored by who they are: your own name is one shade of blue, party/alliance members (including trusts) are a different shade, pets/summons are light green, confirmed NPCs/monsters are red, and any other real player is white — the enemy/monster check is against live entity data, not a name list, so it's accurate for any mob without needing to be kept up to date
- Item names within a message (synthesis results, item drops, fish caught, item use in Combat) are highlighted in light green, matching how the native log itself styles item names
- Stays hidden until a character is actually loaded into the world — won't appear over the character select or loading screens, even when auto-loaded from `default.txt`
- Per-channel colored text, timestamps, and brace coloring (LS1/LS2/Party/Tell/Say only — Shout/Yell/Craft/Combat/NPC/SYS use fixed colors, see above)
- Message text starts at a consistent column sized to the widest username currently in the channel, so lines stay aligned without wasting space on names that aren't there
- Resizable split view — show two channels at once, either side-by-side or stacked, toggled with the Split button or via right-click on a channel tab
- Pop individual channels out into their own window — pop out as many at once as you like, via the Pop Out button (for whichever channel is active) or right-click any tab and choose Pop Out/Pop In directly
- An invert-flashing alert indicator for unseen messages (visual only — no sound)
- Click a line to copy it, or use the context menu to copy name/message/line
- Duplicate-message suppression
- Message history is capped at 5000 lines per channel to bound memory use, backed by a fixed-size ring buffer so the cap can be generous without a performance cost as it fills
- Settings reliably persist across sessions, including after a character login/logout
- In-addon **Settings window** (⚙ gear button) for:
  - Whole-window background transparency
  - Font size (9–45px)
  - Line spacing (0–8px), independent of font size
  - Timestamp format — `HH:MM:SS` or `HH:MM`, 12-hour or 24-hour
  - Colors for timestamps, usernames, and chat text (LS1/LS2/Party/Tell/Say) — set one color for all channels, or a different color per channel, with a one-click reset back to the default (each channel's tab color)

## How chat is captured

Every channel below works the same basic way: read data the game already sends to (or is already about to show) your own client, then display it in a tab. Nothing is ever sent, blocked, or altered — this addon reads state, it never writes it. Specifics per channel:

- Incoming chat is read from the standard Ashita `packet_in` event (message packet `0x017`).
- Outgoing `/say` and `/tell` are mirrored via the `command` event (i.e. read from the command you typed), which is reliable regardless of packet layout.
- Outgoing LS1/LS2/Party lines are mirrored by reading (never modifying) the outgoing chat packet (`0x0B5`) via `packet_out`, since there is no command-hook equivalent for those channels. This addon does not send, alter, or inject any packets — it only reads text from packets the client already sends/receives.
- Craft and Combat are populated differently: those messages are generated by the game client itself (not sent as plain chat text), so this addon reads them via Ashita's `text_in` event — the same mechanism the approved **FishAid** addon uses to detect fishing messages — matching already-visible chat log text against a set of known phrasings, without touching or blocking anything. This pattern set isn't exhaustive yet; some less common combat/craft messages may not be categorized on the first pass. Ordinary player chat (Say, Shout, Yell, Tell, Party, Linkshell, emotes, Unity, etc.) is excluded from this matching entirely by its chat mode, so a chat message can't be mistaken for a combat/craft message just because it happens to contain a similar-looking phrase.
- NPC dialogue is also read via `text_in`, but detected by its chat mode (`e.mode`) rather than by matching text, using the same mode value (150) the approved **Balloon** addon uses to trigger its NPC speech bubbles — this reliably distinguishes NPC dialogue from a player's own `/say`, which uses a different mode. The "NPC Name : dialogue text" split uses the same technique Balloon uses for its own speaker-name extraction. An unprefixed continuation line (an NPC's own second sentence, not a different speaker) inherits the most recent speaker within the same event instead of falling back to a generic "NPC" label.
- Shout and Yell are likewise read via `text_in` and told apart by their chat mode (10 and 11), then split into "Name : message" the same way NPC dialogue is.
- SYS is populated the same way, using chat mode 151 (Balloon's `chat_modes.system`) rather than any text matching. Achievement unlocks and hardcore-character milestones are checked before this mode-based routing (by text, since they can be significant regardless of what mode they arrive under) so they get their own broadcast-to-every-tab treatment instead of just showing up in SYS.
- Auction House, **Checker**, and **conquest** messages are matched by text rather than mode -- Checker and conquest both build their own output via `print()` rather than the game sending it as chat text, so there's no mode to key off of at all, and Auction House messages arrive under the same mode (121) as synthesis results, so a mode check can't tell the two apart. The server's own periodic "Conquest update:" broadcast is likewise matched by text (its exact mode isn't confirmed), requiring an exact known nation name before "- \<level\>" so it can't misfire on unrelated chat formatted similarly.
- FFXI's text is Shift-JIS, not UTF-8, which ImGui doesn't understand on its own -- unconverted, every byte renders as its own "?" placeholder regardless of font. Real Japanese chat text (and Latin-1 accented characters) is properly converted to UTF-8 using the [GdiFonts](https://github.com/ThornyFFXI/gdifonttexture) library's encoding module (MIT license, included under `gdifonts/`), the same technique the approved **Balloon** addon uses. A handful of individual typographic symbols (curly quotes, stars, etc.) are mapped to plain ASCII instead of their real Unicode codepoints, since even once correctly converted, the loaded font's Japanese glyph range doesn't cover those general symbol/punctuation blocks.

## Commands

- `/multichat` — toggle the main window
- `/multichat show` — force the window open and re-center it
- `/multichat reset` — reset all window positions and re-center
- `/multichat trans <0-100>` — set window background opacity (also available as a slider in the Settings window)

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

## License

MIT — see [LICENSE](LICENSE). `gdifonts/` is a bundled third-party dependency under its own MIT license (ThornyFFXI) — see [gdifonts/LICENSE](gdifonts/LICENSE).
