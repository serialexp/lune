/**
 * mahina for editors (doc 74 §13.2). This grammar drives presentation only —
 * highlighting, brackets, outline, indentation. Every diagnostic, scope and
 * rename comes from `mahina lsp`; the drift check keeps the two parsers honest
 * by requiring this one to accept every source mahina's parser accepts.
 *
 * Mirrors src/parser.zig: Lua-shaped statements, `async`/`await`, `??`,
 * compound assignment, `~>>` arithmetic shift, `: Type` annotations.
 */

const PREC = {
  or: 2,
  and: 4,
  compare: 6,
  bor: 8,
  bxor: 10,
  band: 12,
  shift: 14,
  concat: 16,
  add: 18,
  mul: 20,
  unary: 22,
  pow: 24,
  // `a.b(c)[d]:e()` — suffixes bind tighter than any prefix operator.
  suffix: 30,
};

// A block may be empty, which a named rule cannot be in tree-sitter.
const block = ($) => seq(repeat($._statement), optional($.return_statement));

const sep1 = (rule, sep) => seq(rule, repeat(seq(sep, rule)));

module.exports = grammar({
  name: "mahina",

  externals: ($) => [$.comment, $.long_string],

  extras: ($) => [/\s/, $.comment],

  word: ($) => $.identifier,

  conflicts: ($) => [
    [$.call_statement, $._prefix_expression],
  ],

  rules: {
    chunk: ($) => seq(optional($.shebang), repeat($._statement), optional($.return_statement)),

    shebang: (_) => token(seq("#!", /[^\n]*/)),

    _statement: ($) =>
      choice(
        ";",
        $.assignment_statement,
        $.compound_assignment_statement,
        $.call_statement,
        $.local_declaration,
        $.local_function_declaration,
        $.function_declaration,
        $.if_statement,
        $.while_statement,
        $.repeat_statement,
        $.for_numeric_statement,
        $.for_generic_statement,
        $.do_statement,
        $.break_statement,
      ),

    break_statement: (_) => "break",

    return_statement: ($) => seq("return", optional(sep1($._expression, ",")), optional(";")),

    do_statement: ($) => seq("do", block($), "end"),

    while_statement: ($) => seq("while", field("condition", $._expression), "do", block($), "end"),

    repeat_statement: ($) => seq("repeat", block($), "until", field("condition", $._expression)),

    if_statement: ($) =>
      seq(
        "if",
        field("condition", $._expression),
        "then",
        block($),
        repeat($.elseif_clause),
        optional($.else_clause),
        "end",
      ),

    elseif_clause: ($) => seq("elseif", field("condition", $._expression), "then", block($)),

    else_clause: ($) => seq("else", block($)),

    for_numeric_statement: ($) =>
      seq(
        "for",
        field("name", $.identifier),
        "=",
        field("start", $._expression),
        ",",
        field("stop", $._expression),
        optional(seq(",", field("step", $._expression))),
        "do",
        block($),
        "end",
      ),

    for_generic_statement: ($) =>
      seq("for", sep1(field("name", $.identifier), ","), "in", sep1($._expression, ","), "do", block($), "end"),

    local_declaration: ($) =>
      seq("local", sep1($.typed_name, ","), optional(seq("=", sep1($._expression, ",")))),

    typed_name: ($) => seq(field("name", $.identifier), optional($.type_annotation)),

    type_annotation: ($) => seq(":", $.type_name),

    type_name: ($) => sep1($.identifier, "."),

    local_function_declaration: ($) =>
      seq("local", optional("async"), "function", field("name", $.identifier), $._function_body),

    function_declaration: ($) =>
      seq(optional("async"), "function", field("name", $.function_name), $._function_body),

    function_name: ($) =>
      seq(sep1($.identifier, "."), optional(seq(":", field("method", $.identifier)))),

    _function_body: ($) =>
      seq(
        field("parameters", $.parameters),
        optional(field("return_type", $.type_annotation)),
        block($),
        "end",
      ),

    parameters: ($) =>
      seq("(", optional(choice(seq(sep1($.typed_name, ","), optional(seq(",", $.vararg))), $.vararg)), ")"),

    assignment_statement: ($) => seq(sep1($._variable, ","), "=", sep1($._expression, ",")),

    compound_assignment_statement: ($) =>
      seq(
        $._variable,
        choice("+=", "-=", "*=", "/=", "//=", "%=", "&=", "|=", "<<=", ">>=", "~>>=", "..=", "~="),
        $._expression,
      ),

    call_statement: ($) => choice($.call, $.method_call, $.await_expression),

    _variable: ($) => choice($.identifier, $.index, $.field),

    index: ($) => prec.left(PREC.suffix, seq(field("object", $._prefix_expression), "[", field("key", $._expression), "]")),

    field: ($) => prec.left(PREC.suffix, seq(field("object", $._prefix_expression), ".", field("name", $.identifier))),

    call: ($) => prec.left(PREC.suffix, seq(field("function", $._prefix_expression), $.arguments)),

    method_call: ($) =>
      prec.left(PREC.suffix, seq(field("object", $._prefix_expression), ":", field("method", $.identifier), $.arguments)),

    arguments: ($) => seq("(", optional(sep1($._expression, ",")), ")"),

    _prefix_expression: ($) => choice($.identifier, $.index, $.field, $.call, $.method_call, $.parenthesized_expression),

    parenthesized_expression: ($) => seq("(", $._expression, ")"),

    _expression: ($) =>
      choice(
        $.nil,
        $.true,
        $.false,
        $.number,
        $.string,
        $.long_string,
        $.vararg,
        $.function_expression,
        $.table,
        $.binary_expression,
        $.unary_expression,
        $.await_expression,
        $._prefix_expression,
      ),

    nil: (_) => "nil",
    true: (_) => "true",
    false: (_) => "false",
    vararg: (_) => "...",

    function_expression: ($) => seq(optional("async"), "function", $._function_body),

    await_expression: ($) => prec(PREC.unary, seq("await", $._expression)),

    unary_expression: ($) => prec(PREC.unary, seq(choice("not", "-", "#", "~"), $._expression)),

    binary_expression: ($) =>
      choice(
        ...[
          ["or", PREC.or],
          ["??", PREC.or],
          ["and", PREC.and],
          ["<", PREC.compare],
          [">", PREC.compare],
          ["<=", PREC.compare],
          [">=", PREC.compare],
          ["~=", PREC.compare],
          ["==", PREC.compare],
          ["|", PREC.bor],
          ["~", PREC.bxor],
          ["&", PREC.band],
          ["<<", PREC.shift],
          [">>", PREC.shift],
          ["~>>", PREC.shift],
          ["+", PREC.add],
          ["-", PREC.add],
          ["*", PREC.mul],
          ["/", PREC.mul],
          ["//", PREC.mul],
          ["%", PREC.mul],
        ].map(([op, p]) => prec.left(p, seq(field("left", $._expression), field("operator", op), field("right", $._expression)))),
        prec.right(PREC.concat, seq(field("left", $._expression), field("operator", ".."), field("right", $._expression))),
        prec.right(PREC.pow, seq(field("left", $._expression), field("operator", "^"), field("right", $._expression))),
      ),

    table: ($) => seq("{", optional(seq(sep1($._table_field, choice(",", ";")), optional(choice(",", ";")))), "}"),

    _table_field: ($) =>
      choice(
        seq("[", field("key", $._expression), "]", "=", field("value", $._expression)),
        seq(field("key", $.identifier), "=", field("value", $._expression)),
        field("value", $._expression),
      ),

    number: (_) => {
      const decimal = /[0-9]+/;
      const hex = /[0-9a-fA-F]+/;
      return token(
        choice(
          seq(choice("0x", "0X"), choice(seq(hex, optional(seq(".", optional(hex)))), seq(".", hex)), optional(seq(/[pP]/, optional(/[+-]/), decimal))),
          seq(choice(seq(decimal, optional(seq(".", optional(decimal)))), seq(".", decimal)), optional(seq(/[eE]/, optional(/[+-]/), decimal))),
        ),
      );
    },

    string: (_) =>
      token(
        choice(
          seq('"', repeat(choice(/[^"\\\n]/, /\\(.|\n)/)), '"'),
          seq("'", repeat(choice(/[^'\\\n]/, /\\(.|\n)/)), "'"),
        ),
      ),

    identifier: (_) => /[A-Za-z_][A-Za-z0-9_]*/,
  },
});
