# Switchtone design language

The look of gabrimatic.info, for the app: the same family as the other apps, in the site's palette, type, icon style and layout. The site's magazine concepts stay on the site.

## Vibe

Dark, quiet, precise. One thing per surface, generous space, nothing decorative. Everything looks drawn by one hand.

## Colour

- Ink `#1b262c` is the ground. Ice `#bbe1fa` is the content. Accent `#3282b8` is the one thing that matters on a surface.
- Only these three and their alpha blends. Primary text ice, secondary 0.68, quiet 0.44.
- Dark first. The light appearance swaps ground and content and keeps the accent.

## Type

- IBM Plex Sans on every surface the app draws. Native controls keep the system font.
- Titles light, at 22 to 24. Body 400 at 13, line height 1.5 to 1.7. Small labels 11 to 13, tabular figures for numbers.

## Icons

- One solid glyph that plainly shows the product, on a 24-unit grid, with detail cut out of it.
- Exactly one accent part. No outlines, gradients on the glyph, 3D or gloss.
- App icon: the glyph at 68% of the site's glass tile: ink under a faint ice fill and a soft top sheen.
- Menu bar: the same drawing as a template at 18 points.
- Every glyph is checked at 16 px first, and every mark at 18 points.

## Surfaces

- Glass means interactive: glass only on things you click or focus. Everything else stays flat on ink.
- Glass tiers from the site: fill 0.05, 0.08, 0.13, 0.20 of ice, edge 0.09 to 0.22, brighter when raised, a soft dark shadow, never a 3D dome.
- Hairlines at ice 0.25, dividers at 0.08.

## Layout

- Spacing scale 4, 8, 16, 24, 32, 48. Card padding and gaps come from it.
- Elements align to one left edge. Label left, value right. Icon tiles sit in even rows with an equal gap.
- Hover lifts a control slightly and brings the accent in. Focus always shows an accent ring.

## Motion

- Calm and short: 150 ms hover, 300 ms fades, 220 ms nudges, ease out.
- At most one ambient loop on a surface. Reduce Motion gives the finished state at once.

## Menus

- Every menu or panel opens with the app's name on its first line at full strength, with its state under it.

## Settings

- Every app uses one window: a flat 200 pt sidebar of panes, a hairline, and the pane beside it under its title.
- The pane title is IBM Plex Sans 22 light. Sidebar rows are 32 pt tall, with the selected row in accent at 0.34.
- Groups sit on the ground with a faint fill, and rows hold a title and detail on the left and the control on the right.
