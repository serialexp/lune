// External scanner for mahina: comments (line comments and long-bracket block
// comments) and long-bracket strings, whose closing bracket must repeat the
// opening bracket's `=` level. That is not expressible in a context-free
// grammar, so it lives here.

#include "tree_sitter/parser.h"

enum TokenType { COMMENT, LONG_STRING };

void *tree_sitter_mahina_external_scanner_create(void) { return NULL; }
void tree_sitter_mahina_external_scanner_destroy(void *p) { (void)p; }
unsigned tree_sitter_mahina_external_scanner_serialize(void *p, char *buf) {
  (void)p;
  (void)buf;
  return 0;
}
void tree_sitter_mahina_external_scanner_deserialize(void *p, const char *buf, unsigned n) {
  (void)p;
  (void)buf;
  (void)n;
}

static void adv(TSLexer *l) { l->advance(l, false); }

// At `[`: read `[`, any `=`s, then `[`; return the number of `=`s, or -1.
static int open_bracket(TSLexer *l) {
  if (l->lookahead != '[') return -1;
  adv(l);
  int level = 0;
  while (l->lookahead == '=') {
    level++;
    adv(l);
  }
  if (l->lookahead != '[') return -1;
  adv(l);
  return level;
}

// Consume through the matching close bracket. False at end of input.
static bool scan_to_close(TSLexer *l, int level) {
  for (;;) {
    if (l->eof(l)) return false;
    if (l->lookahead != ']') {
      adv(l);
      continue;
    }
    adv(l);
    int n = 0;
    while (l->lookahead == '=') {
      n++;
      adv(l);
    }
    if (n == level && l->lookahead == ']') {
      adv(l);
      return true;
    }
    // Not the closer. A `]` now at lookahead may itself start one: loop on it.
  }
}

bool tree_sitter_mahina_external_scanner_scan(void *p, TSLexer *l, const bool *valid) {
  (void)p;
  while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\n' || l->lookahead == '\r') {
    l->advance(l, true);
  }

  if (l->lookahead == '-' && valid[COMMENT]) {
    adv(l);
    if (l->lookahead != '-') return false;
    adv(l);
    if (l->lookahead == '[') {
      int level = open_bracket(l);
      if (level >= 0) {
        if (!scan_to_close(l, level)) return false;
        l->mark_end(l);
        l->result_symbol = COMMENT;
        return true;
      }
    }
    // A line comment (also after a `--[` that was not a long bracket).
    while (!l->eof(l) && l->lookahead != '\n' && l->lookahead != '\r') adv(l);
    l->mark_end(l);
    l->result_symbol = COMMENT;
    return true;
  }

  if (l->lookahead == '[' && valid[LONG_STRING]) {
    int level = open_bracket(l);
    if (level < 0) return false;
    if (!scan_to_close(l, level)) return false;
    l->mark_end(l);
    l->result_symbol = LONG_STRING;
    return true;
  }

  return false;
}
