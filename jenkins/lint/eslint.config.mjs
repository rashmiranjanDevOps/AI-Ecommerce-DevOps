import globals from "globals";

// Only rules that catch real bugs are errors. Each page loads one script file, so cross-file
// globals are not checked (no-undef is off).
export default [
  {
    files: ["**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: { ...globals.browser },
    },
    rules: {
      "no-dupe-keys": "error",
      "no-dupe-args": "error",
      "no-redeclare": "error",
      "no-unreachable": "error",
      "no-const-assign": "error",
      "no-func-assign": "error",
      "no-self-assign": "error",
      "no-unsafe-negation": "error",
      "use-isnan": "error",
      "valid-typeof": "error",
      eqeqeq: "warn",
      "no-eval": "error",
      "no-implied-eval": "error",
    },
  },
];
