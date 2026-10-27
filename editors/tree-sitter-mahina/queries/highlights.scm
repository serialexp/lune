; Presentation only: scope-aware colouring (locals vs globals) comes from the
; server's semantic tokens (doc 74 P4); this is the syntactic layer.

(comment) @comment
(shebang) @comment

(string) @string
(long_string) @string
(number) @number

[(nil) (true) (false)] @constant.builtin
(vararg) @variable.special

[
  "local" "function" "async" "await" "return" "end" "do" "then"
  "if" "elseif" "else" "while" "repeat" "until" "for" "in"
] @keyword
(break_statement) @keyword

[ "and" "or" "not" ] @keyword.operator

[
  "+" "-" "*" "/" "//" "%" "^" "#" "&" "|" "~" "<<" ">>" "~>>"
  "==" "~=" "<" ">" "<=" ">=" ".." "??"
  "=" "+=" "-=" "*=" "/=" "//=" "%=" "&=" "|=" "<<=" ">>=" "~>>=" "..="
] @operator

[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
[ "," ";" ":" "." ] @punctuation.delimiter

(identifier) @variable

(type_name (identifier) @type)

(parameters (typed_name name: (identifier) @variable.parameter))

(local_function_declaration name: (identifier) @function)
(function_name (identifier) @function .)
(function_name method: (identifier) @function.method)
(function_name (identifier) @module (identifier))

(call function: (identifier) @function.call)
(call function: (field name: (identifier) @function.call))
(method_call method: (identifier) @function.method.call)

(field name: (identifier) @property)
(table (identifier) @property)
