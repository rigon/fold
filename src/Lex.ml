
open Pure

type literal =
  | Bool   of bool         (* True False       *)
  | Char   of char         (* 'x' '-' '0' '\t' *)
  | Float  of float        (* 3.14 00.1 1.0000 *)
  | Int    of int          (* 100 42 0 012345  *)
  | String of string       (* "hello" "" "x"   *)
  | Symbol of string       (* a foo Bar + >>=  *)
[@@deriving show, ord]

module Literal = struct
  type t = literal

  let compare = compare_literal

  include Printable.Make(struct
      type nonrec t = t
      let pp = pp_literal
    end)

  let to_string = function
    | Bool   x -> String.capitalize_ascii (string_of_bool x)
    | Char   x -> "'%c'" % x
    | Float  x -> string_of_float x
    | Int    x -> string_of_int x
    | String x -> "\"%s\"" % x
    | Symbol x -> x

  let eof = Symbol "<EOF>"
end


module Location = struct
  type t =
    { line   : int;
      column : int;
      length : int }
    [@@deriving show]

  let empty =
    { line   = 0;
      column = 0;
      length = 0 }

  include Printable.Make(struct
      type nonrec t = t
      let pp = pp
    end)

  let to_string self =
    "%d,%d/%d" % (self.line, self.column, self.length)
end


module Token = struct
  type t = Literal.t
    [@@deriving show]

  let location _ = Location.empty
  let literal  = id

  include Printable.Make(struct
      type nonrec t = t
      let pp = pp
    end)

  let to_string lit = Literal.to_string lit
end



let decimal_literal =
  [%sedlex.regexp? '0'..'9', Star ('0'..'9' | '_')]

let hex_literal =
  [%sedlex.regexp?
    '0', Chars "xX", ('0'..'9' | 'A'..'F' | 'a'..'f'),
    Star ('0'..'9' | 'A'..'F' | 'a'..'f' | '_')]

let oct_literal =
  [%sedlex.regexp? '0', Chars "oO", '0'..'7', Star ('0'..'7' | '_') ]

let bin_literal =
  [%sedlex.regexp? '0', Chars "bB", '0'..'1', Star ('0'..'1' | '_') ]

let int_literal =
  [%sedlex.regexp? decimal_literal | hex_literal | oct_literal | bin_literal ]

let float_literal =
  [%sedlex.regexp?
    '0'..'9', Star ('0'..'9' | '_'),
    Opt ('.', Star ('0'..'9' | '_')),
    Opt (Chars "eE", Opt (Chars "+-"), '0'..'9', Star ('0'..'9' | '_'))]

let identifier_char =
  [%sedlex.regexp? alphabetic | Chars "_'"]

let operator_char =
  [%sedlex.regexp? Chars "!$%&*+-./\\:<=>?@^|~#" ]

let delimeter_char =
  [%sedlex.regexp? Chars "{}[]`,;\"'"]

let name_literal =
  [%sedlex.regexp? Plus (operator_char | delimeter_char)]

let comment =
  [%sedlex.regexp? "--", Star (Compl '\n')]

let white_space =
  [%sedlex.regexp? Plus (' ' | '\t')]


module Lexer = struct
  type t =
    { mutable lexbuf      : Sedlexing.lexbuf;
      mutable peek_cache  : Token.t option;
      mutable line_start  : int;
      mutable line_count  : int;
      mutable group_count : int }


  let increment_line self =
    self.line_start <- Sedlexing.lexeme_end self.lexbuf;
    self.line_count <- self.line_count + 1


  let current_location { lexbuf; line_count; line_start } =
    let open Sedlexing in
    let open Location in
    { line   = line_count;
      column = lexeme_end lexbuf - line_start - lexeme_length lexbuf + 1;
      length = lexeme_length lexbuf }


  let current_lexeme self =
    Sedlexing.Utf8.lexeme self.lexbuf


  exception Error of
    { lexeme   : string;
      location : Location.t;
      message  : string }


  let error self message =
    let lexeme   = current_lexeme self in
    let location = current_location self in
    raise (Error { message; lexeme; location })


  let rec read_literal self =
    let lexbuf = self.lexbuf in
    match%sedlex lexbuf with
    (* Whitespace and comment *)
    | Plus (white_space | comment) ->
      read_literal self

    (* Int literal *)
    | int_literal ->
      Int (int_of_string (current_lexeme self))

    (* Float literal *)
    | float_literal ->
      Float (float_of_string (current_lexeme self))

    (* Unit literal *)
    | '(', Star ((white_space | '\n') | comment), ')' ->
      Symbol "()"

    (* Group start *)
    | '('  ->
      self.group_count <- (self.group_count + 1);
      Symbol (current_lexeme self)

    (* Group end *)
    | ')' ->
      self.group_count <- (self.group_count - 1);

      if self.group_count < 0 then
        error self "unbalanced parenthesis"
      else
        Symbol (current_lexeme self)

    (* XXX: Quoted symbols are not part of the lexer for now. *)
    (* | '`',  (name_literal | Plus identifier_char) -> *)
    (* let lexeme = current_lexeme self in *)
    (* Symbol (String.sub lexeme 1 (String.length lexeme - 1)) *)

    | '"',  Star (Compl '"'), '"' ->
      let lexeme = current_lexeme self in
      String (String.sub lexeme 1 (String.length lexeme - 2))

    | '\'', Compl '\'', '\'' ->
      Char (String.get (current_lexeme self) 1)

    | "True"  -> Bool true
    | "False" -> Bool false

    (* Names (operators and identifiers) *)
    | name_literal | Plus identifier_char ->
      Symbol (current_lexeme self)

    (* Newline symbol *)
    | '\n' ->
      increment_line self;
      read_literal self

    (* EOF symbol *)
    | eof -> Literal.eof

    (* Everything else is illegal *)
    | any ->
      error self "illegal character"

    (* Sedlex: the last branch must be a catch-all error case *)
    | _ -> undefined ()


  let read self =
    let literal  = read_literal self in
    let _location = current_location self in
    literal


  let next self =
    match self.peek_cache with
    | None ->
      read self

    | Some x ->
      self.peek_cache <- None;
      x


  let peek self =
    match self.peek_cache with
    | Some x ->
      x

    | None ->
      let token = read self in
      self.peek_cache <- Some token;
      token


  let junk self =
    ignore (next self)


  let from_lexbuf lexbuf =
    { lexbuf;
      peek_cache  = None;
      line_start  = 0;
      line_count  = 0;
      group_count = 0 }


  let from_string s =
    from_lexbuf (Sedlexing.Utf8.from_string s)


  let from_channel c =
    from_lexbuf (Sedlexing.Utf8.from_channel c)
end


