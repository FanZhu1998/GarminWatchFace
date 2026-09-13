import Toybox.Lang;

// Dark-theme tokens from fan-zhu.com (assets/css/style.css :root).
// Monkey C colors are 0xRRGGBB with no alpha, so the rgba tokens are pre-composited
// onto --page (#080e18): out = a*fg + (1-a)*bg per channel.
module Theme {
    const PAGE       = 0x080e18;   // --page          awake canvas
    const AOD_BG     = 0x000000;   // always-on canvas (AMOLED pixel budget, not a site token)
    const SURFACE    = 0x0d1523;   // --surface       reserved: cell fill if the rail should read as cards
    const INK        = 0xe8eef7;   // --ink           time digits
    const INK_2      = 0xa7b8ce;   // --ink-2         reserved: secondary prose
    const MUTED      = 0x7f92a9;   // --muted         date, rail labels, footer, separators
    const ACCENT     = 0x7dabdd;   // --accent        rail values, ring progress, neutral training status
    const ACCENT_HI  = 0xa7c8ee;   // --accent-hi     pressed-cell highlight (the site's hover color)
    const ACCENT_2   = 0x628ab8;   // --accent-2      seconds, AOD time: the receded tone
    const ACCENT_DIM = 0x182434;   // --accent-dim    over --page: halo behind the phone-connected dot
    const BULL       = 0x46bf94;   // --bull          positive verdict
    const BEAR       = 0xe5776c;   // --bear          negative verdict
    const LINE       = 0x1e242e;   // --line   over --page: ring track (kept faint by design)
    const LINE_2     = 0x2c323c;   // --line-2 over --page: reserved
    const GRID       = 0x3f4b5a;   // structural rules on the face (rail panel): brighter steel so
                                   // sections read clearly at arm's length, still calm on the navy
}
