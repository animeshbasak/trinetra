# README demo (HyperFrames)

Source of the demo at the top of the README (`docs/assets/demo.webp`, `docs/assets/demo.mp4`).
`SPEC.md` is the brief; `compositions/menu.html` rebuilds the menu from `App/MenuContent.swift`.

```bash
cd Assets/demo
curl -sLo assets/gsap.min.js https://cdn.jsdelivr.net/npm/gsap@3.15.0/dist/gsap.min.js   # not committed
npx hyperframes check --json
npx hyperframes render --quality delivery -o demo.mp4
ffmpeg -i demo.mp4 -vf "fps=15,scale=960:-1:flags=lanczos" -c:v libwebp_anim -quality 70 -loop 0 ../../docs/assets/demo.webp
```

Every push to `main` updates this demo to show what changed (see `CLAUDE.md`).
