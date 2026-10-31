# Visual identity and asset guide

## Design language

**Memory, without the noise.**

The visual identity separates two jobs: a spacious, editorial cover introduces the project; the
architecture diagram explains its actual mechanisms. The network is a **memory metaphor**, not
an executable neural network, vector database or automatic graph traversal.

- Ink `#070c11`, ivory `#eff2ea`, mint `#75efd9`, lilac `#b3b1f7`.
- Sparse, seeded 3D geometry; depth controls point size and edge visibility.
- Main copy has its own quiet area. Avoid putting diagrams behind words.
- Mint highlights the active core and selected evidence. Peripheral memory is quieter, not deleted.
- No invented speed results, model-intelligence claims, unlimited-window claims or popularity metrics.

## Assets

| Asset | Intended surface | Size |
|---|---|---|
| `hero.zh.png`, `hero.en.png` | README covers | 1600 × 900 |
| `social-preview.png` | GitHub repository social preview | 1280 × 640 |
| `poster.zh.png` | Chinese promotional post | 1080 × 1440 |
| `logo.svg`, `logo.png` | Project mark | vector / 512 × 512 |
| `../architecture.svg`, `../architecture.png` | Chinese system explanation | 1600 × 1100 |
| `../architecture.en.svg`, `../architecture.en.png` | English system explanation | 1600 × 1100 |
| `memory-network.gif`, `memory-network.png` | Network motion / static fallback | 960 × 540 / 1600 × 900 |
| `quickstart.gif`, `quickstart.png` | Command sequence / static fallback | 1120 × 630 / 1600 × 900 |
| `neuron-harness-film.mp4` | Silent promotional film | 1920 × 1080, 30 fps, 24 seconds |
| `index.html` | Local interactive presentation and asset gallery | responsive |

The GitHub social preview is a ready-to-upload image. Generating it does **not** update the
repository's social-preview setting. No remote publication is performed by these scripts.

## Rebuild

Install Python 3, Pillow, NumPy and ffmpeg. `ffprobe` should be on PATH. From the repository root:

```powershell
py -3 docs/brand/render_visuals.py --all --contact-sheet
py -3 docs/brand/check_visuals.py
pwsh -NoProfile -File tests/e2e.ps1
```

On another operating system use the installed Python executable instead of `py -3`.
Font lookup supports installed Windows, Noto, DejaVu and macOS families; all required fonts must
exist or the renderer stops rather than silently generating missing glyphs. `NH_FONT_DIR` can
point to a directory of locally installed fonts. No font binaries are redistributed; Windows
renders use Segoe UI, Microsoft YaHei and Consolas from the operating system. Other fonts may
slightly alter layout and require renewed acceptance checks.

`check_visuals.py` checks text-canvas bounds, dimensions, media decoding, changing GIF frames,
GIF duration/size budgets and README links. It is **not** an aesthetic acceptance test.

Serve only the documentation directory to view the interactive presentation:

```powershell
py -3 -m http.server 8773 --bind 127.0.0.1 --directory docs
```

Open `http://127.0.0.1:8773/brand/`. No CDN, external font request or analytics is required. The
page honors reduced-motion preference and offers a pause control. README GIFs have static links
because GitHub cannot supply the same pause behavior for an embedded GIF.

## Publishing boundaries

- English and Chinese covers use separate copy and layouts; do not crop the poster to make a cover.
- Keep the static fallback and explanatory prose alongside animations.
- Command animations intentionally abbreviate arguments. Use the README and specification for actual integration.
- Existing `docs/promo/` assets remain in place for old links; new README references use `docs/brand/`.
- Changes are kept local; the rendering and check scripts do not publish anything themselves.
  No tag, release, repository metadata or GitHub Pages setting is changed by them.
