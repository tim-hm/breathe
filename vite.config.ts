// Configuration for `vp fmt` (mise run fmt:text), which formats markdown, YAML,
// JSON, and TOML. There is no Vite app here — vp reads its options from this
// file, and refuses to run outside a JS workspace at all, which is also why the
// root package.json exists.
//
// Formatting options are left at their defaults deliberately: vp is version-
// pinned in .mise.toml, so the defaults cannot shift underneath a commit.
export default {
  fmt: {
    // A paragraph is one physical line; where it breaks on screen is the
    // reader's editor's business, not the file's. This also joins any paragraph
    // someone hard-wrapped by hand, and keeps tables compact instead of
    // column-aligned — aligned tables reflow every row when one cell changes.
    proseWrap: "never",
    // vp already honours .gitignore. These are the tracked files another tool
    // owns the format of, where a reformat is churn at best.
    ignorePatterns: [
      // `check:sqlx` regenerates this cache and compares it; a reformat reads
      // as drift.
      ".sqlx/**",
      // Xcode writes these, and rewrites them whenever the catalogue changes.
      "ios/Breathe/Assets.xcassets/**",
    ],
  },
};
