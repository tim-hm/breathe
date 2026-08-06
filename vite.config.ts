// Configuration for `vp fmt` (mise run fmt:text), which formats markdown, YAML,
// JSON, and TOML. There is no Vite app here — vp reads its options from this
// file, and refuses to run outside a JS workspace at all, which is also why the
// root package.json exists.
export default {
  fmt: {
    // A paragraph is one physical line; where it breaks on screen is the
    // reader's editor's business, not the file's. This also joins back any
    // paragraph someone hard-wrapped by hand.
    proseWrap: "never",

    // Not a line limit — nothing here wraps prose. It is the threshold vp uses
    // to decide whether a markdown table fits when column-aligned: narrower and
    // it pads the cells, wider and it leaves them compact. At the default 80
    // this repo landed on both styles at once, twice within one file. 200 clears
    // the widest table we have, so every table aligns and the choice is uniform.
    //
    // Compact-everywhere is not reachable: it would need a width below the
    // narrowest table (~70), which is under the longest TOML and YAML arrays and
    // explodes them one element per line.
    printWidth: 200,

    // vp already honours .gitignore. These are the tracked files another tool
    // owns the format of, where a reformat is churn at best.
    ignorePatterns: [
      // `check:sqlx` regenerates this cache and compares it; a reformat reads
      // as drift.
      ".sqlx/**",
      // Xcode writes these, and rewrites them whenever a catalogue changes —
      // the app's, and BreatheUI's palette.
      "ios/**/*.xcassets/**",
    ],
  },
};
