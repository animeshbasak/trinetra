GOAL:    A developer watching the README GIF understands in one pass: Trinetra keeps the Mac awake with the lid
         closed while an agent works, shows what the agent did and what the Mac is doing, then lets it sleep.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps. Silent on purpose: it ships as an autoplaying muted README GIF/WebP.
TIME:    23 s x 30 = 690 frames.
LOOK:    ground #E7E2D8 warm stone, flat, 2% fibre noise; ink #1A1814; one accent #B45309 (amber, the eye's iris)
         on one word per caption only. Product surfaces are the real dark macOS menu (#2C2C30 panel, #1E1E22 menu bar).
         Display: Inter 700, 76 px, -2% tracking, left column x=140..960. Product UI rebuilt from App/MenuContent.swift
         at 2.2x (13 px callout -> 29 px). Panel shadow 0 30px 80px rgba(0,0,0,.35).
OBJECTS: the macOS menu bar with the real third-eye template icon (Assets/icon/MenuBar-*.svg) and the network readout;
         the Trinetra menu with its real labels and the values from Animesh's screenshot (4 Nov 2026):
         Claude Code · PAARTH-TRADER, 48 prompts · 30 files edited · 336 commands · 2h 20m active;
         CPU 13 %, GPU 58 %, Memory 25.2 GB, Temperature 43 °C, Power · battery 18.3 W, Network ↓ 482 B/s ↑ 482 B/s;
         Held awake 16h 3m for agents · used 31 % battery. A macOS arrow cursor, 64 px. The real app icon on the end card.
MOTION:  enter expo.out 0.5 s; camera power2.inOut 0.7 s; exit power3.in 0.25 s; switch knob 0.18 s power3.out;
         counters 0.9 s power2.out; sparklines draw 1.0 s; captions per word blur 6px->0, 0.07 s apart, no translate.
SHOTS:   0.0-3.4  cursor enters, clicks the eye; the menu opens from the eye. Caption "Claude is two hours into a task."
         3.4-7.0  cursor clicks "Keep awake with the lid closed"; the switch turns on, header becomes "lid can close",
                  menu bar eye fills. Caption "Close the lid. It keeps working." (accent: keeps working)
         7.0-11.0 camera tracks down to Agents; the session summary counts up. Caption "See what every agent did."
         11.0-15.2 camera to System; six tiles fill, sparklines draw. Caption "CPU, GPU, heat and power. Live."
         15.2-18.6 Today line; camera back to the top; header "Idle — Mac can sleep"; the eye closes.
                  Caption "Work done. It lets the Mac sleep." (accent: sleep)
         18.6-23.0 end card: the app icon lands, wordmark wipes in, line + repo address hold 2.5 s.
BANNED:  dark navy void; glow; purple/blue gradients; glass cards; everything centred; everything fading in at once;
         titles that drift after landing; click rings; bounce on UI; three cards in a row; logo docked in a corner;
         invented UI or labels not in MenuContent.swift.
QA:      t=2.6 menu open under the eye; t=5.0 switch on, header "lid can close"; t=9.5 summary at 48/30/336;
         t=13.8 tiles at final values; t=18.0 idle header and closed eye; t=21.5 end card complete.
