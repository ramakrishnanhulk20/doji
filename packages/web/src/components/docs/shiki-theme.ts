// A code theme built only from the Doji tokens, so code blocks match the rest of the product.
// Hex values mirror :root in globals.css, because the build tool reads this file outside the browser.
const paper = "#F1E6D2";
const paperDim = "#B9AE9C";
const beniText = "#E35D68";
const safe = "#7FB3B5";
const watch = "#A9B8D6";
const auction = "#B7A6E6";

export const dojiCodeTheme = {
  name: "doji",
  type: "dark" as const,
  colors: {
    "editor.background": "#221E1B",
    "editor.foreground": paper,
  },
  settings: [
    { settings: { foreground: paper } },
    { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: paperDim } },
    { scope: ["punctuation", "meta.brace", "meta.delimiter"], settings: { foreground: paperDim } },
    { scope: ["keyword", "storage", "storage.type", "storage.modifier"], settings: { foreground: beniText } },
    { scope: ["string", "string.quoted", "punctuation.definition.string"], settings: { foreground: safe } },
    { scope: ["constant.numeric", "constant.language", "constant.character", "support.constant"], settings: { foreground: watch } },
    { scope: ["entity.name.function", "support.function", "meta.function-call"], settings: { foreground: auction } },
    { scope: ["entity.name.type", "entity.name.class", "support.type", "support.class"], settings: { foreground: auction } },
    { scope: ["variable.parameter", "variable.other.property", "meta.object-literal.key"], settings: { foreground: paper } },
    { scope: ["entity.name.tag", "markup.heading"], settings: { foreground: beniText } },
    { scope: ["entity.other.attribute-name"], settings: { foreground: watch } },
  ],
};
