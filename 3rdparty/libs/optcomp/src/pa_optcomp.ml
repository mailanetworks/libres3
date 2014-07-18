(*
 * pa_optcomp.ml
 * -------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of optcomp.
 *)

open Camlp4.Sig
open Camlp4.PreCast

external filter : 'a Gram.not_filtered -> 'a = "%identity"
external not_filtered : 'a -> 'a Gram.not_filtered = "%identity"

(* Subset of supported caml types *)
type typ =
  | Tvar of string
  | Tbool
  | Tint
  | Tchar
  | Tstring
  | Ttuple of typ list

(* Subset of supported caml values *)
type value =
  | Bool of bool
  | Int of int
  | Char of char
  | String of string
  | Tuple of value list

type ident = string
    (* An identifier. It is either a lower or a upper identifier. *)

module Env = Map.Make(struct type t = ident let compare = compare end)

type env = value Env.t

type directive =
  | Dir_let of Ast.patt * Ast.expr
  | Dir_default of Ast.patt * Ast.expr
  | Dir_if of Ast.expr
  | Dir_else
  | Dir_elif of Ast.expr
  | Dir_endif
  | Dir_include of Ast.expr
  | Dir_error of Ast.expr
  | Dir_warning of Ast.expr
  | Dir_directory of Ast.expr

  (* This one is not part of optcomp but this is one of the directives
     handled by camlp4 we probably want to use. *)
  | Dir_default_quotation of Ast.expr

(* Quotations are evaluated by the token filters, but are expansed
   after. Evaluated quotations are kept in this table, which quotation
   id to to values: *)
let quotations : (int, value) Hashtbl.t = Hashtbl.create 42

let next_quotation_id =
  let r = ref 0 in
  fun _ -> incr r; !r

(* +-----------------------------------------------------------------+
   | Environment                                                     |
   +-----------------------------------------------------------------+ *)

let env = ref Env.empty
let define id value = env := Env.add id value !env

let _ =
  define "ocaml_version" (Scanf.sscanf Sys.ocaml_version "%d.%d" (fun major minor -> Tuple [Int major; Int minor]))

let dirs = ref []
let add_include_dir dir = dirs := dir :: !dirs

(* +-----------------------------------------------------------------+
   | Dependencies                                                    |
   +-----------------------------------------------------------------+ *)

module String_set = Set.Make(String)

(* All depencies of the file being parsed *)
let dependencies = ref String_set.empty

(* Where to write dependencies *)
let dependency_filename = ref None

(* The file being parsed. This is set when the first (token, location)
   pair is fetched. *)
let source_filename = ref None

let write_depencies () =
  match !dependency_filename, !source_filename with
    | None, _
    | _, None ->
        ()

    | Some dependency_filename, Some source_filename ->
        let oc = open_out dependency_filename in
        if not (String_set.is_empty !dependencies) then begin
          output_string oc "# automatically generated by optcomp\n";
          output_string oc source_filename;
          output_string oc ": ";
          output_string oc (String.concat " " (String_set.elements !dependencies));
          output_char oc '\n'
        end;
        close_out oc

(* +-----------------------------------------------------------------+
   | Value to expression/pattern conversion                          |
   +-----------------------------------------------------------------+ *)

let rec expr_of_value _loc = function
  | Bool true -> <:expr< true >>
  | Bool false -> <:expr< false >>
  | Int x -> <:expr< $int:string_of_int x$ >>
  | Char x -> <:expr< $chr:Char.escaped x$ >>
  | String x -> <:expr< $str:String.escaped x$ >>
  | Tuple [] -> <:expr< () >>
  | Tuple [x] -> expr_of_value _loc x
  | Tuple l -> <:expr< $tup:Ast.exCom_of_list (List.map (expr_of_value _loc) l)$ >>

let rec patt_of_value _loc = function
  | Bool true -> <:patt< true >>
  | Bool false -> <:patt< false >>
  | Int x -> <:patt< $int:string_of_int x$ >>
  | Char x -> <:patt< $chr:Char.escaped x$ >>
  | String x -> <:patt< $str:String.escaped x$ >>
  | Tuple [] -> <:patt< () >>
  | Tuple [x] -> patt_of_value _loc x
  | Tuple l -> <:patt< $tup:Ast.paCom_of_list (List.map (patt_of_value _loc) l)$ >>

(* +-----------------------------------------------------------------+
   | Value printing                                                  |
   +-----------------------------------------------------------------+ *)

let string_of_value string_of_bool v =
  let buf = Buffer.create 128 in
  let rec aux = function
    | Bool b ->
        Buffer.add_string buf (string_of_bool b)
    | Int n ->
        Buffer.add_string buf (string_of_int n)
    | Char ch ->
        Buffer.add_char buf '\'';
        Buffer.add_string buf (Char.escaped ch);
        Buffer.add_char buf '\''
    | String s ->
        Buffer.add_char buf '"';
        Buffer.add_string buf (String.escaped s);
        Buffer.add_char buf '"'
    | Tuple [] ->
        Buffer.add_string buf "()"
    | Tuple (x :: l) ->
        Buffer.add_char buf '(';
        aux x;
        List.iter
          (fun x ->
             Buffer.add_string buf ", ";
             aux x)
          l;
        Buffer.add_char buf ')'
  in
  aux v;
  Buffer.contents buf

let string_of_value_o v =
  string_of_value
    (function
       | true -> "true"
       | false -> "false")
    v

let string_of_value_r v =
  string_of_value
    (function
       | true -> "True"
       | false -> "False")
    v

let string_of_value_no_pretty v =
  let buf = Buffer.create 128 in
  let rec aux = function
    | Bool b ->
        Buffer.add_string buf (string_of_bool b)
    | Int n ->
        Buffer.add_string buf (string_of_int n)
    | Char ch ->
        Buffer.add_char buf ch
    | String s ->
        Buffer.add_string buf s;
    | Tuple [] ->
        Buffer.add_string buf "()"
    | Tuple (x :: l) ->
        Buffer.add_char buf '(';
        aux x;
        List.iter
          (fun x ->
             Buffer.add_string buf ", ";
             aux x)
          l;
        Buffer.add_char buf ')'
  in
  aux v;
  Buffer.contents buf

(* +-----------------------------------------------------------------+
   | Expression evaluation                                           |
   +-----------------------------------------------------------------+ *)

let rec type_of_value = function
  | Bool _ -> Tbool
  | Int _ -> Tint
  | Char _ -> Tchar
  | String _ -> Tstring
  | Tuple l -> Ttuple (List.map type_of_value l)

let rec string_of_type = function
  | Tvar v -> "'" ^ v
  | Tbool -> "bool"
  | Tint -> "int"
  | Tchar -> "char"
  | Tstring -> "string"
  | Ttuple l -> "(" ^ String.concat " * " (List.map string_of_type l) ^ ")"

let invalid_type loc expected real =
  Loc.raise loc (Failure
                   (Printf.sprintf "this expression has type %s but is used with type %s"
                      (string_of_type real) (string_of_type expected)))

let type_of_patt patt =
  let rec aux (a, n) = function
    | <:patt< $tup:x$ >> ->
      let l, x = List.fold_left
        (fun (l, x) patt -> let t, x = aux x patt in (t :: l, x))
        ([], (a, n)) (Ast.list_of_patt x []) in
      (Ttuple(List.rev l), x)
    | _ ->
        (Tvar(Printf.sprintf "%c%s"
                (char_of_int (Char.code 'a' + a))
                (if n = 0 then "" else string_of_int n)),
         if a = 25 then (0, n + 1) else (a + 1, n))
  in
  fst (aux (0, 0) patt)

let rec eval env = function

  (* Literals *)
  | <:expr< true >> -> Bool true
  | <:expr< false >> -> Bool false
  | <:expr< $int:x$ >> -> Int(int_of_string x)
  | <:expr< $chr:x$ >> -> Char(Camlp4.Struct.Token.Eval.char x)
  | <:expr< $str:x$ >> -> String(Camlp4.Struct.Token.Eval.string ~strict:() x)

  (* Tuples *)
  | <:expr< $tup:x$ >> -> Tuple(List.map (eval env) (Ast.list_of_expr x []))

  (* Variables *)
  | <:expr@loc< $lid:x$ >>
  | <:expr@loc< $uid:x$ >> ->
    begin try
      Env.find x env
    with
        Not_found ->
          Loc.raise loc (Failure (Printf.sprintf "unbound value %s" x))
    end

  (* Value comparing *)
  | <:expr< $x$ = $y$ >> -> let x, y = eval_same env x y in Bool(x = y)
  | <:expr< $x$ < $y$ >> -> let x, y = eval_same env x y in Bool(x < y)
  | <:expr< $x$ > $y$ >> -> let x, y = eval_same env x y in Bool(x > y)
  | <:expr< $x$ <= $y$ >> -> let x, y = eval_same env x y in Bool(x <= y)
  | <:expr< $x$ >= $y$ >> -> let x, y = eval_same env x y in Bool(x >= y)
  | <:expr< $x$ <> $y$ >> -> let x, y = eval_same env x y in Bool(x <> y)

  (* min and max *)
  | <:expr< min $x$ $y$ >> -> let x, y = eval_same env x y in min x y
  | <:expr< max $x$ $y$ >> -> let x, y = eval_same env x y in max x y

  (* Arithmetic *)
  | <:expr< $x$ + $y$ >> -> Int(eval_int env x + eval_int env y)
  | <:expr< $x$ - $y$ >> -> Int(eval_int env x - eval_int env y)
  | <:expr< $x$ * $y$ >> -> Int(eval_int env x * eval_int env y)
  | <:expr< $x$ / $y$ >> -> Int(eval_int env x / eval_int env y)
  | <:expr< $x$ mod $y$ >> -> Int(eval_int env x mod eval_int env y)

  (* Boolean operations *)
  | <:expr< not $x$ >> -> Bool(not (eval_bool env x))
  | <:expr< $x$ or $y$ >> -> Bool(eval_bool env x || eval_bool env y)
  | <:expr< $x$ || $y$ >> -> Bool(eval_bool env x || eval_bool env y)
  | <:expr< $x$ && $y$ >> -> Bool(eval_bool env x && eval_bool env y)

  (* String operations *)
  | <:expr< $x$ ^ $y$ >> -> String(eval_string env x ^ eval_string env y)

  (* Pair operations *)
  | <:expr< fst $x$ >> -> fst (eval_pair env x)
  | <:expr< snd $x$ >> -> snd (eval_pair env x)

  (* Conversions *)
  | <:expr@loc< to_string $x$ >> ->
    String(string_of_value_no_pretty (eval env x))
  | <:expr@loc< to_int $x$ >> ->
    Int
      (match eval env x with
         | String x -> begin
             try
               int_of_string x
             with exn ->
               Loc.raise loc exn
           end
         | Int x ->
             x
         | Char x ->
             int_of_char x
         | Bool _ ->
             Loc.raise loc (Failure "cannot convert a boolean to an integer")
         | Tuple _ ->
             Loc.raise loc (Failure "cannot convert a tuple to an integer"))
  | <:expr@loc< to_bool $x$ >> ->
    Bool
      (match eval env x with
         | String x -> begin
             try
               bool_of_string x
             with exn ->
               Loc.raise loc exn
           end
         | Int x ->
             Loc.raise loc (Failure "cannot convert an integer to a boolean")
         | Char x ->
             Loc.raise loc (Failure "cannot convert a character to a boolean")
         | Bool x ->
             x
         | Tuple _ ->
             Loc.raise loc (Failure "cannot convert a tuple to a boolean"))
  | <:expr@loc< to_char $x$ >> ->
    Char
      (match eval env x with
         | String x ->
             if String.length x = 1 then
               x.[0]
             else
               Loc.raise loc (Failure (Printf.sprintf "cannot convert a string of length %d to a character" (String.length x)))
         | Int x -> begin
             try
               char_of_int x
             with exn ->
               Loc.raise loc exn
           end
         | Char x ->
             x
         | Bool _ ->
             Loc.raise loc (Failure "cannot convert a boolean to a character")
         | Tuple _ ->
             Loc.raise loc (Failure "cannot convert a tuple to a character"))

  (* Pretty printing *)
  | <:expr@loc< show $x$ >> ->
    String(string_of_value_o (eval env x))

  (* Let-binding *)
  | <:expr< let $p$ = $x$ in $y$ >> ->
    let vx = eval env x in
    let env =
      try
        bind true env p vx
      with Exit ->
        invalid_type (Ast.loc_of_expr x) (type_of_patt p) (type_of_value vx)
    in
    eval env y

  | e -> Loc.raise (Ast.loc_of_expr e) (Stream.Error "expression not supported")

and bind override env patt value = match patt with
  | <:patt< $lid:id$ >>
  | <:patt< $uid:id$ >> ->
    if override || not (Env.mem id env) then
      Env.add id value env
    else
      env

  | <:patt< $tup:patts$ >> ->
    let patts = Ast.list_of_patt patts [] in
    begin match value with
      | Tuple values when List.length values = List.length patts ->
          List.fold_left2 (bind override) env patts values
      | _ ->
          raise Exit
    end

  | <:patt< _ >> ->
    env

  | _ ->
      Loc.raise (Ast.loc_of_patt patt) (Stream.Error "pattern not supported")

and eval_same env ex ey =
  let vx = eval env ex and vy = eval env ey in
  let tx = type_of_value vx and ty = type_of_value vy in
  if tx = ty then
    (vx, vy)
  else
    invalid_type (Ast.loc_of_expr ey) tx ty

and eval_int env e = match eval env e with
  | Int x -> x
  | v -> invalid_type (Ast.loc_of_expr e) Tint (type_of_value v)

and eval_bool env e = match eval env e with
  | Bool x -> x
  | v -> invalid_type (Ast.loc_of_expr e) Tbool (type_of_value v)

and eval_string env e = match eval env e with
  | String x -> x
  | v -> invalid_type (Ast.loc_of_expr e) Tstring (type_of_value v)

and eval_char env e = match eval env e with
  | Char x -> x
  | v -> invalid_type (Ast.loc_of_expr e) Tchar (type_of_value v)

and eval_pair env e = match eval env e with
  | Tuple [x; y] -> (x, y)
  | v -> invalid_type (Ast.loc_of_expr e) (Ttuple [Tvar "a"; Tvar "b"]) (type_of_value v)

(* +-----------------------------------------------------------------+
   | Parsing of directives                                           |
   +-----------------------------------------------------------------+ *)

let rec skip_space stream = match Stream.peek stream with
  | Some((BLANKS _ | COMMENT _), _) ->
      Stream.junk stream;
      skip_space stream
  | _ ->
      ()

let rec parse_eol stream =
  let tok, loc = Stream.next stream in
  match tok with
    | BLANKS _ | COMMENT _ ->
        parse_eol stream
    | NEWLINE | EOI ->
        ()
    | _ ->
        Loc.raise loc (Stream.Error "end of line expected")

(* Return wether a keyword can be interpreted as an identifier *)
let keyword_is_id str =
  let rec aux i =
    if i = String.length str then
      true
    else
      match str.[i] with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' ->
            aux (i + 1)
        | _ ->
            false
  in
  aux 0

let parse_ident stream =
  skip_space stream;
  let tok, loc = Stream.next stream in
  begin match tok with
    | LIDENT id | UIDENT id ->
        (id, loc)
    | KEYWORD kwd when keyword_is_id kwd ->
        (kwd, loc)
    | _ ->
        Loc.raise loc (Stream.Error "identifier expected")
  end

let parse_until entry is_stop_token stream =
  (* Lists of opened brackets *)
  let opened_brackets = ref [] in
  let eoi = ref None in
  let end_loc = ref Loc.ghost in

  (* Return the next token of [stream] until all opened parentheses
     have been closed and a newline is reached *)
  let rec next_token _ =
    match !eoi with
    | Some _ as x -> x
    | None ->
        Some(match Stream.next stream, !opened_brackets with
           | (tok, loc), [] when is_stop_token tok ->
               end_loc := loc;
               let x = (EOI, loc) in
               eoi := Some x;
               x

           | (EOI, loc), _ ->
               end_loc := loc;
               let x = (EOI, loc) in
               eoi := Some x;
               x

           | ((KEYWORD ("(" | "[" | "{" as b) | SYMBOL ("(" | "[" | "{" as b)), _) as x, l ->
               opened_brackets := b :: l;
               x

           | ((KEYWORD ")" | SYMBOL ")"), loc) as x, "(" :: l ->
               opened_brackets := l;
               x

           | ((KEYWORD "]" | SYMBOL "]"), loc) as x, "[" :: l ->
               opened_brackets := l;
               x

           | ((KEYWORD "}" | SYMBOL "}"), loc) as x, "{" :: l ->
               opened_brackets := l;
               x

           | x, _ ->
               x)
  in

  let expr =
    Gram.parse_tokens_before_filter entry
      (not_filtered (Stream.from next_token))
  in
  (expr, Loc.join !end_loc)

let parse_expr stream =
  parse_until Syntax.expr_eoi (fun tok -> tok = NEWLINE) stream

let parse_patt stream =
  parse_until Syntax.patt_eoi (function
                                 | SYMBOL "=" | KEYWORD "=" -> true
                                 | _ -> false) stream

let parse_directive stream = match Stream.peek stream with
  | Some((KEYWORD "#" | SYMBOL "#"), loc) ->  begin
      Stream.junk stream;

      let dir, loc_dir = parse_ident stream in

      match dir with

        | "let" ->
            let patt, _ = parse_patt stream in
            let expr, end_loc = parse_expr stream in
            Some(Dir_let(patt, expr), Loc.merge loc end_loc)

        | "let_default" ->
            let patt, _ = parse_patt stream in
            let expr, end_loc = parse_expr stream in
            Some(Dir_default(patt, expr), Loc.merge loc end_loc)

        | "if" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_if expr, Loc.merge loc end_loc)

        | "else" ->
            parse_eol stream;
            Some(Dir_else, Loc.merge loc loc_dir)

        | "elif" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_elif expr, Loc.merge loc end_loc)

        | "endif" ->
            parse_eol stream;
            Some(Dir_endif, Loc.merge loc loc_dir)

        | "include" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_include expr, Loc.merge loc end_loc)

        | "directory" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_directory expr, Loc.merge loc end_loc)

        | "error" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_error expr, Loc.merge loc end_loc)

        | "warning" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_warning expr, Loc.merge loc end_loc)

        | "default_quotation" ->
            let expr, end_loc = parse_expr stream in
            Some(Dir_default_quotation expr, Loc.merge loc end_loc)

        | _ ->
            Loc.raise loc_dir (Stream.Error (Printf.sprintf "unknown directive ``%s''" dir))
    end

  | _ ->
      None

let parse_command_line_define str =
  match Gram.parse_string Syntax.expr (Loc.mk "<command line>") str with
    | <:expr< $lid:id$ = $e$ >>
    | <:expr< $uid:id$ = $e$ >> -> define id (eval !env e)
    | _ -> invalid_arg str

(* +-----------------------------------------------------------------+
   | Block skipping                                                  |
   +-----------------------------------------------------------------+ *)

let rec skip_line stream =
  match Stream.next stream with
    | NEWLINE, _ -> ()
    | EOI, loc -> Loc.raise loc (Stream.Error "#endif missing")
    | _ -> skip_line stream

let rec next_directive stream = match parse_directive stream with
  | Some dir -> dir
  | None -> skip_line stream; next_directive stream

let rec next_endif stream =
  let dir, loc = next_directive stream in
  match dir with
    | Dir_if _ -> skip_if stream; next_endif stream
    | Dir_else
    | Dir_elif _
    | Dir_endif -> dir
    | _ -> next_endif stream

and skip_if stream =
  let dir, loc = next_directive stream in
  match dir with
    | Dir_if _ ->
        skip_if stream;
        skip_if stream

    | Dir_else ->
        skip_else stream

    | Dir_elif _ ->
        skip_if stream

    | Dir_endif ->
        ()

    | _ -> skip_if stream

and skip_else stream =
  let dir, loc = next_directive stream in
  match dir with
    | Dir_if _ ->
        skip_if stream;
        skip_else stream

    | Dir_else ->
        Loc.raise loc (Stream.Error "#else without #if")

    | Dir_elif _ ->
        Loc.raise loc (Stream.Error "#elif without #if")

    | Dir_endif ->
        ()

    | _ ->
        skip_else stream

(* +-----------------------------------------------------------------+
   | Token filtering                                                 |
   +-----------------------------------------------------------------+ *)

type context = Ctx_if | Ctx_else

(* State of the token filter *)
type state = {
  stream : (Gram.Token.t * Loc.t) Stream.t;
  (* Input stream *)

  mutable bol : bool;
  (* Wether we are at the beginning of a line *)

  mutable stack : context list;
  (* Nested contexts *)

  on_eoi : Gram.Token.t * Loc.t -> Gram.Token.t * Loc.t;
  (* Eoi handler, it is used to restore the previous sate on #include
     directives *)
}

(* Read and return one token *)
let really_read state =
  let tok, loc = Stream.next state.stream in
  state.bol <- tok = NEWLINE;
  match tok with
    | QUOTATION ({ q_name = "optcomp" } as quot) ->
        let id = next_quotation_id () in
        Hashtbl.add quotations id (eval !env (Gram.parse_string
                                                Syntax.expr_eoi
                                                (Loc.move `start quot.q_shift loc)
                                                quot.q_contents));

        (* Replace the quotation by its id *)
        (QUOTATION { quot with q_contents = string_of_int id }, loc)

    | EOI ->
        (* If end of input is reached, we call the eoi handler. It may
           continue if we were parsing an included file *)
        if state.stack <> [] then
          Loc.raise loc (Stream.Error "#endif missing");
        state.on_eoi (tok, loc)

    | _ ->
        (tok, loc)

(* Return the next token from a stream, interpreting directives. *)
let rec next_token lexer state_ref =
  let state = !state_ref in
  if state.bol then
    match parse_directive state.stream, state.stack with
      | Some(Dir_if e, _), _ ->
          let rec aux e =
            if eval_bool !env e then begin
              state.stack <- Ctx_if :: state.stack;
              next_token lexer state_ref
            end else
              match next_endif state.stream with
                | Dir_else ->
                    state.stack <- Ctx_else :: state.stack;
                    next_token lexer state_ref

                | Dir_elif e ->
                    aux e

                | Dir_endif ->
                    next_token lexer state_ref

                | _ ->
                    assert false
          in
          aux e

      | Some(Dir_else, loc), ([] | Ctx_else :: _) ->
          Loc.raise loc (Stream.Error "#else without #if")

      | Some(Dir_elif _, loc), ([] | Ctx_else :: _) ->
          Loc.raise loc (Stream.Error "#elif without #if")

      | Some(Dir_endif, loc), [] ->
          Loc.raise loc (Stream.Error "#endif without #if")

      | Some(Dir_else, loc), Ctx_if :: l ->
          skip_else state.stream;
          state.stack <- l;
          next_token lexer state_ref

      | Some(Dir_elif _, loc), Ctx_if :: l ->
          skip_if state.stream;
          state.stack <- l;
          next_token lexer state_ref

      | Some(Dir_endif, loc), _ :: l ->
          state.stack <- l;
          next_token lexer state_ref

      | Some(Dir_let(patt, expr), _), _ ->
          let value = eval !env expr in
          env := (
            try
              bind true !env patt value;
            with Exit ->
              invalid_type (Ast.loc_of_expr expr) (type_of_patt patt) (type_of_value value)
          );
          next_token lexer state_ref

      | Some(Dir_default(patt, expr), _), _ ->
          let value = eval !env expr in
          env := (
            try
              bind false !env patt value;
            with Exit ->
              invalid_type (Ast.loc_of_expr expr) (type_of_patt patt) (type_of_value value)
          );
          next_token lexer state_ref

      | Some(Dir_include e, _), _ ->
          let fname = eval_string !env e in
          (* Try to looks up in all include directories *)
          let fname =
            try
              List.find (fun dir -> Sys.file_exists (Filename.concat dir fname)) !dirs
            with
                (* Just try in the current directory *)
                Not_found -> fname
          in
          dependencies := String_set.add fname !dependencies;
          let ic = open_in fname in
          let nested_state = {
            stream = lexer fname ic;
            bol = true;
            stack = [];
            on_eoi = (fun _ ->
                        (* Restore previous state and close channel on
                           eoi *)
                        state_ref := state;
                        close_in ic;
                        next_token lexer state_ref)
          } in
          (* Replace current state with the new one *)
          state_ref := nested_state;
          next_token lexer state_ref

      | Some(Dir_directory e, loc), _ ->
          let dir = eval_string !env e in
          add_include_dir dir;
          next_token lexer state_ref

      | Some(Dir_error e, loc), _ ->
          Loc.raise loc (Failure (eval_string !env e))

      | Some(Dir_warning e, loc), _ ->
          Syntax.print_warning loc (eval_string !env e);
          next_token lexer state_ref

      | Some(Dir_default_quotation e, loc), _ ->
          Syntax.Quotation.default := eval_string !env e;
          next_token lexer state_ref

      | None, _ ->
          really_read state

  else
    really_read state

let default_lexer fname ic =
  Token.Filter.filter (Gram.get_filter ()) (filter (Gram.lex (Loc.mk fname) (Stream.of_channel ic)))

let stream_filter lexer filter stream =
  (* Set the source filename *)
  begin
    match !source_filename with
      | Some _ ->
          ()
      | None ->
          match Stream.peek stream with
            | None ->
                ()
            | Some(tok, loc) ->
                source_filename := Some(Loc.file_name loc)
  end;
  let state_ref = ref { stream = stream;
                        bol = true;
                        stack = [];
                        on_eoi = (fun x -> x) } in
  filter (Stream.from (fun _ -> Some(next_token lexer state_ref)))

let filter ?(lexer=default_lexer) stream = stream_filter lexer (fun x -> x) stream

(* +-----------------------------------------------------------------+
   | Quotations expansion                                            |
   +-----------------------------------------------------------------+ *)

let get_quotation_value str =
  Hashtbl.find quotations (int_of_string str)

let expand f loc _ contents =
  try
    f loc (get_quotation_value contents)
  with exn ->
    Loc.raise loc (Failure "fatal error in optcomp!")

(* +-----------------------------------------------------------------+
   | Registration                                                    |
   +-----------------------------------------------------------------+ *)

let _ =
  Camlp4.Options.add "-let" (Arg.String parse_command_line_define)
    "<string> Binding for a #let directive.";
  Camlp4.Options.add "-I" (Arg.String add_include_dir)
    "<string> Add a directory to #include search path.";
  Camlp4.Options.add "-depend"
    (Arg.String (fun filename -> dependency_filename := Some filename))
    "<file> Write dependencies to <file>.";

  Pervasives.at_exit write_depencies;

  Syntax.Quotation.add "optcomp" Syntax.Quotation.DynAst.expr_tag (expand expr_of_value);
  Syntax.Quotation.add "optcomp" Syntax.Quotation.DynAst.patt_tag (expand patt_of_value);

  Gram.Token.Filter.define_filter (Gram.get_filter ()) (stream_filter default_lexer)