(** Helper functions for debugging. **)

open Lplib open Base open Extra

(** Printing functions. *)
module D = struct

  let ignore : 'a pp = fun _ _ -> ()

  let log_and_return logger el = logger el; el

  let log_and_raise logger exc = logger exc; raise exc

  let depth : int pp = fun ppf l ->
    for _i = 1 to l do out ppf " " done; out ppf "%d. " l

  let bool : bool pp = fun ppf b -> out ppf "%B" b

  let int : int pp = fun ppf i -> out ppf "%d" i

  let string : string pp = fun ppf s -> out ppf "\"%s\"" s

  let option : 'a pp -> 'a option pp = fun elt ppf o ->
    match o with
    | None -> out ppf "None"
    | Some x -> out ppf "Some(%a)" elt x

  let pair : 'a pp -> 'b pp -> ('a * 'b) pp = fun elt1 elt2 ppf (x1,x2) ->
    out ppf "(%a,%a)" elt1 x1 elt2 x2

  let list : 'a pp -> 'a list pp = fun elt ppf l ->
    match l with
    | [] -> out ppf "[]"
    | x::l ->
      out ppf "[%a" elt x;
      let f x = out ppf "; %a" elt x in
      List.iter f l;
      out ppf "]"

  let array : 'a pp -> 'a array pp = fun elt ppf a ->
    let n = Array.length a in
    if n = 0 then out ppf "[]"
    else begin
      out ppf "[%a" elt a.(0);
      for i = 1 to n-1 do out ppf "; %a" elt a.(i) done;
      out ppf "]"
    end

  let hashtbl : 'a pp -> 'b pp -> ('a, 'b) Hashtbl.t pp = fun key elt ->
    let tbl ppf = Hashtbl.iter (fun k v -> out ppf "%a,%a; " key k elt v) in
    fun ppf -> out ppf "[%a]" tbl

  let map : (('key -> 'elt -> unit) -> 'map -> unit)
    -> 'key pp -> string -> 'elt pp -> string -> 'map pp =
    fun iter key sep1 elt sep2 ppf m ->
    let f k t = out ppf "%a%s%a%s" key k sep1 elt t sep2 in
    out ppf "["; iter f m; out ppf "]"

  let strmap : 'a pp -> 'a StrMap.t pp = fun elt ->
    map StrMap.iter string "," elt ";"

  let intmap : 'a pp -> 'a IntMap.t pp = fun elt ->
    map IntMap.iter int "," elt ";"

  let iter ?sep:(sep = Format.pp_print_cut) iter elt ppf v =
    let is_first = ref true in
    let elt v =
      if !is_first then (is_first := false) else sep ppf ();
      elt ppf v
    in
    iter elt v

  (* To be used in a hov (and not default) box *)
  let surround beg fin inside =
    fun fmt v -> out fmt "%s@;<0 2>@[<hv>%a@]@,%s" beg inside v fin

  let bracket inside = surround "[" "]" inside

end

(** [time_of log f x] computes [f x] and prints the time for computing it. *)
let time_of : ('a outfmt -> 'a) -> string -> (unit -> 'b) -> 'b =
  fun log s f ->
  if false && Logger.log_enabled () then begin
    let t0 = Sys.time () in
    let log _ = log "%s time: %f" s (Sys.time () -. t0) in
    try f () |> D.log_and_return log
    with e -> e |> D.log_and_raise log
  end else f ()

(** To record time with [record_time]. *)
let do_record_time = ref false
let do_print_time = ref true

type task =
  | Lexing
  | Parsing
  | Scoping
  | Rewriting
  | Typing
  | Solving
  | Reading
  | Sharing
  | Writing

let index = function
  | Lexing -> 0
  | Parsing -> 1
  | Scoping -> 2
  | Rewriting -> 3
  | Typing -> 4
  | Solving -> 5
  | Reading -> 6
  | Sharing -> 7
  | Writing -> 8

let nb_tasks = 9

let task_name ppf = function
  | 0 -> string ppf "lexing"
  | 1 -> string ppf "parsing"
  | 2 -> string ppf "scoping"
  | 3 -> string ppf "rewriting"
  | 4 -> string ppf "typing"
  | 5 -> string ppf "solving"
  | 6 -> string ppf "reading"
  | 7 -> string ppf "sharing"
  | 8 -> string ppf "writing"
  | _ -> assert false

(** [record_time s f] records under [s] the time spent in calling [f].
    [print_time ()] outputs the recorded times. *)
let record_time, print_time =
  let tm = Float.Array.make nb_tasks 0.0 and call_stack = ref [] in
  let add_time task d =
    let i = index task in Float.Array.(set tm i (get tm i +. d)) in
  let record_time : task -> (unit -> unit) -> unit = fun task f ->
    if !do_record_time then begin
      let t0 = Sys.time () in
      call_stack := task::!call_stack;
      let end_task () =
        let d = Sys.time () -. t0 in
        call_stack := List.tl !call_stack;
        add_time task d;
        match !call_stack with
        | [] -> ()
        | task::_ -> add_time task (-. d)
      in
      try f (); end_task () with e -> end_task (); raise e
    end else f ()
  and print_time : float -> unit -> unit = fun t0 () ->
    if !do_record_time && !do_print_time then begin
      let total = Sys.time () -. t0 in
      Format.printf "total %.2fs" total;
      let task i d =
        Format.printf " %a %.2fs (%.0f%%)" task_name i d (100.0 *. d /. total)
      in
      Float.Array.iteri task tm;
      let d = total -. (Float.Array.fold_left (+.) 0.0 tm) in
      Format.printf " other %.2fs (%.0f%%)@." d (100.0 *. d /. total)
    end
  in
  record_time, print_time

(** [stream_iter f s] is the same as [Stream.iter f s] but records the time in
   peeking the elements of the stream. *)
let stream_iter : ('a -> unit) -> 'a Stream.t -> unit =
  if not !do_print_time then Stream.iter else fun f strm ->
  let peek strm =
    let r = ref None in
    record_time Parsing (fun () -> r := Stream.peek strm); !r
  in
  let rec do_rec () =
    match peek strm with
      Some a -> Stream.junk strm; ignore(f a); do_rec ()
    | None -> ()
  in
  do_rec ()
