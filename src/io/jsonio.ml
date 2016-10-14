(**************************************************************************)
(*  Copyright (C) 2014-2016, Skylable Ltd. <info-copyright@skylable.com>  *)
(*                                                                        *)
(*  Permission to use, copy, modify, and distribute this software for     *)
(*  any purpose with or without fee is hereby granted, provided that the  *)
(*  above copyright notice and this permission notice appear in all       *)
(*  copies.                                                               *)
(*                                                                        *)
(*  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL         *)
(*  WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED         *)
(*  WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE      *)
(*  AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL  *)
(*  DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA    *)
(*  OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER     *)
(*  TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR      *)
(*  PERFORMANCE OF THIS SOFTWARE.                                         *)
(**************************************************************************)

(* based on ezjonsm and jsonfilter *)

open Boundedio

module Error = struct
  type range = (int * int) * (int * int)
  let pp_range ppf ((l1,c1),(l2,c2)) =
    Fmt.pf ppf "%d:%d-%d:%d" l1 c1 l2 c2

  type t = Syntax of Jsonm.error | Expected of string * Jsonm.lexeme
  let pp ppf = function
  | Syntax e -> Jsonm.pp_error ppf e
  | Expected (expected, actual) ->
      Fmt.pf ppf "Expected %s but got %a" expected Jsonm.pp_lexeme actual

  exception Json of range option * t

  let () =
    Printexc.register_printer (function
      | Json (range, err) ->
          (* TODO: prefix *)
          Some (Fmt.strf "JSON error at %a: %a"
                  (Fmt.option pp_range) range pp err)
      | _ -> None
      )

  let fail_json d e =
    let range = match d with
    | Some d -> Some (Jsonm.decoded_range d)
    | None -> None in
    Json(range, e) |> fail
end

type json_primitive = [`String of string | `Bool of bool | `Float of float | `Null]
type json = [json_primitive | `O of (string * json) list | `A of json list]
type lexeme = Jsonm.lexeme

type +'a t = Jsonm.decoder option * Jsonm.lexeme Lwt_stream.t

let rec lexeme stream d = match Jsonm.decode d with
| `Lexeme l -> Lwt.return_some l
| `Error e -> Error.(fail_json (Some d) (Syntax e))
| `End -> Lwt.return_none
| `Await -> Lwt_stream.get stream >>= function
  | None ->
      Jsonm.Manual.src d "" 0 0; lexeme stream d
  | Some str ->
      assert (String.length str > 0);
      Jsonm.Manual.src d str 0 (String.length str);
      lexeme stream d

let of_strings ?encoding stream =
  let d = Jsonm.decoder ?encoding `Manual in
  Some d, Lwt_stream.from (fun () -> lexeme stream d)

let of_string ?encoding str =
  of_strings ?encoding (Lwt_stream.of_list [str])

let substream (d, signals) =
  let depth = ref 0 in
  let process = fun v ->
    begin match v with
    | Some (`Os | `As) -> incr depth
    | Some (`Oe | `Ae) -> decr depth
    | Some #Jsonm.lexeme | None -> ()
    end;
    if !depth = 0 then decr depth;
    return v
  in
  let next () =
    if !depth < 0 then return_none
    else Lwt_stream.get signals >>= process
  in
  d, Lwt_stream.from next

let expect msg f (d,signals) = Lwt_stream.peek signals >>= function
  | Some l ->
    if f l then substream (d,signals) |> return
    else Error.(Expected(msg, l) |> fail_json d)
  | None -> assert false

let is_array_start = function `As -> true | #Jsonm.lexeme -> false
let is_object_start = function `Os -> true | #Jsonm.lexeme -> false

let expect_array = expect "array" is_array_start
let expect_object = expect "object" is_object_start
let expect_primitive (d,signals) = Lwt_stream.next signals >>= function
  | #json_primitive as p -> return p
  | #Jsonm.lexeme as l ->
      Error.(Expected("primitive", l) |> fail_json d)

let fields (d, signals) =
  let rec next () = Lwt_stream.next signals >>= function
    | `Os -> next ()
    | `Oe -> return_none
    | `Name n -> return_some (n, substream (d,signals))
    | #Jsonm.lexeme -> assert false
  in
  Lwt_stream.from next

let elements (d,signals) =
  let next () = Lwt_stream.is_empty signals >>= function
    | true -> return_none
    | false -> return_some (substream (d,signals))
  in
  Lwt_stream.from next

let rec next signals =
  Lwt_stream.next signals >>= value signals
and value signals = function
| #json_primitive as v -> return v
| `As -> arr signals []
| `Os -> obj signals []
| `Ae | `Oe | `Name _ -> assert false
and arr signals lst = Lwt_stream.next signals >>= function
  | `Ae -> return (`A (List.rev lst))
  | v -> value signals v >>= fun e -> arr signals (e :: lst)
and obj signals lst = Lwt_stream.next signals >>= function
  | `Oe ->
      (* not required, but preserving original order makes it easier to test *)
      return (`O (List.rev lst))
  | `Name n -> next signals >>= fun v ->
      obj signals ((n, v) :: lst)
  | #json_primitive | `As | `Os | `Ae -> assert false

let to_json (_, signals) = next signals

let expect_eof (d,signals) =
  Lwt_stream.get signals >>= function
  | None -> return_unit
  | Some l -> Error.(fail_json d (Expected("EOF", l)))

let always _ = true
let drain (_, signals) = Lwt_stream.junk_while always signals

let observe ~prefix (d,stream) =
  let observe_lexeme l =
    Logs.debug (fun m -> m "%s: %a" prefix Jsonm.pp_lexeme l);
    l
  in
  d, if Logs.level () = Some Logs.Debug then begin
    Lwt_stream.map observe_lexeme stream
  end
  else stream

let of_json json =
  let stream, push = Lwt_stream.create () in
  let rec value = function
  | #json_primitive as v -> push (Some v)
  | `A lst ->
      push (Some `As);
      List.iter value lst;
      push (Some `Ae)
  | `O lst ->
      push (Some `Os);
      List.iter fields lst;
      push (Some `Oe)
  and fields (n, v) =
    push (Some (`Name n));
    value v
  in
  value json;
  push None;
  None, stream

let to_strings ?minify (_,signals) =
  (* we could use `Manual, but it doesn't support -safe-string,
     strings don't have to be the same size though, so just flush the buffer when size is exceeded *)
  let limit = Lwt_io.default_buffer_size () in
  let buf = Buffer.create (2 * limit) in
  let e = Jsonm.encoder ?minify (`Buffer buf) in
  let flush () =
    let s = Buffer.contents buf in
    Buffer.reset buf;
    if String.length s = 0 then return_none
    else return_some s
  in
  let encode v k =
    match Jsonm.encode e v with
    | `Ok ->
        if Buffer.length buf < limit then k ()
        else flush ()
    | `Partial -> assert false
  in
  let rec get () =
    Lwt_stream.get signals >>= function
    | None -> encode `End flush
    | Some l ->
        encode (`Lexeme l) get
  in
  Lwt_stream.from get

let to_string ?minify stream =
  let b = Buffer.create (Lwt_io.default_buffer_size ()) in
  to_strings ?minify stream |>
  Lwt_stream.iter (Buffer.add_string b) >>= fun () ->
  return (Buffer.contents b)