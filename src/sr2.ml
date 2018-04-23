(** Type-checking and inference. *)

open Console
open Terms
open Print
open Infer2

(** [subst_from_constrs cs] builds a //typing substitution// from the list  of
    constraints [cs]. The returned substitution is given by a couple of arrays
    [(xs,ts)] of the same length.  The array [xs] contains the variables to be
    substituted using the terms of [ts] at the same index. *)
let subst_from_constrs : unif list -> tvar array * term array = fun cs ->
  let rec build_sub acc cs =
    match cs with
    | []          -> acc
    | (c,a,b)::cs ->
       let (ha,argsa) = get_args a and (hb,argsb) = get_args b in
       let na = List.length argsa and nb = List.length argsb in
        match (unfold ha, unfold hb) with
        | (Symb(sa), Symb(sb)) when sa == sb && na=nb && !(sa.sym_rules)=[] ->
           build_sub acc
             (List.fold_left2 (fun l t1 t2 -> (c,t1,t2)::l) cs argsa argsb)
        | (Vari(x),_) when argsa = [] -> build_sub ((x,b)::acc) cs
        | (_,Vari(x)) when argsb = [] -> build_sub ((x,a)::acc) cs
        | (_,_) -> build_sub acc cs
  in
  let (vs,ts) = List.split (build_sub [] cs) in
  (Array.of_list vs, Array.of_list ts)

(** [check_rule r] check whether rule [r] is well-typed. The program
    fails gracefully in case of error. *)
let check_rule : sym * rule -> unit = fun (s,rule) ->
  if !debug_sr then log "sr" "checking %a" pp_rule (s, rule);
  (** We process the LHS to replace pattern variables by metavariables. *)
  let arity = Bindlib.mbinder_arity rule.rhs in
  let metas = Array.init arity (fun _ -> None) in
  let rec to_m : term -> tbox = fun t ->
    let to_m_binder b x = to_m (Bindlib.subst b (mkfree x)) in
    match unfold t with
    | Vari(x)     -> _Vari x
    | Symb(s)     -> _Symb s
    | Abst(a,t)   -> _Abst (to_m a) (Bindlib.binder_name t) (to_m_binder t)
    | Appl(t,u)   -> _Appl (to_m t) (to_m u)
    | Patt(i,n,a) ->
        begin
          let a = Array.map to_m a in
          let k = Array.length a in
          match i with
          | None    ->
              let (mt,_) = build_meta_type [] false in (* FIXME [] *)
              let m = add_meta n mt k in
              _Meta m a
          | Some(i) ->
              match metas.(i) with
              | Some(m) -> _Meta m a
              | None    ->
                  let (mt,_) = build_meta_type [] false in (* FIXME [] *)
                  let m = add_meta n mt k in
                  metas.(i) <- Some(m);
                  _Meta m a
        end
    | Type        -> assert false (* Cannot appear in LHS. *)
    | Kind        -> assert false (* Cannot appear in LHS. *)
    | Prod(_,_)   -> assert false (* Cannot appear in LHS. *)
    | Meta(_,_)   -> assert false (* Cannot appear in LHS. *)
    | TEnv(_,_)   -> assert false (* Cannot appear in LHS. *)
  in
  let lhs = List.map (fun p -> Bindlib.unbox (to_m p)) rule.lhs in
  let lhs = add_args (Symb(s)) lhs in
  (** We substitute the RHS with the corresponding metavariables.*)
  let fn m =
    let m = match m with Some(m) -> m | None -> assert false in
    let names = Array.init m.meta_arity (Printf.sprintf "x%i") in
    TE_Some(Bindlib.mbinder_from_fun names (fun e -> Meta(m,e)))
  in
  let te_envs = Array.map fn metas in
  let rhs = Bindlib.msubst rule.rhs te_envs in
  (* Infer the type of the LHS and the constraints. *)
  let (lhs_constrs, ty_lhs) = constraints_of (raw_infer Ctxt.empty) lhs in
  if !debug_sr then
    log "sr" "%a : %a%a" pp lhs pp ty_lhs pp_unifs lhs_constrs;
  (* Turn constraints into a substitution and apply it. *)
  let (xs,ts) = subst_from_constrs lhs_constrs in
  let p = Bindlib.box_pair (lift rhs) (lift ty_lhs) in
  let p = Bindlib.unbox (Bindlib.bind_mvar xs p) in
  let (rhs,ty_lhs) = Bindlib.msubst p ts in
  (* Check that the RHS has the same type as the LHS. *)
  ignore (without_generating_constraints (has_type Ctxt.empty rhs) ty_lhs)
