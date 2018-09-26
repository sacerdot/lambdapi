(** Implementation of the REWRITE tactic. *)

open Timed
open Terms
open Console
open Proof
open Solve
open Print

(** Logging function for the rewrite tactic. *)
let log_rewr = new_logger 'w' "rewr" "informations for the rewrite tactic"
let log_rewr = log_rewr.logger

(** Rewrite pattern. *)
type rw_patt =
  | RW_Term           of term
  | RW_InTerm         of term
  | RW_InIdInTerm     of (term, term) Bindlib.binder
  | RW_IdInTerm       of (term, term) Bindlib.binder
  | RW_TermInIdInTerm of term * (term, term) Bindlib.binder
  | RW_TermAsIdInTerm of term * (term, term) Bindlib.binder

(** Type for a term which  contains a set of  free  variables  that need  to be
    substituted, during some unification operation.  This usually  refers  to a
    quantified LHS of an equality proof. *)
type to_subst = tvar array * term

(** [add_refs] is given a term containing wildcards and substitutes each with a
    reference  to  None.  This is used for unification,  by performing  all the
    substitutions in-place. *)
let rec add_refs : term -> term = fun t ->
  match t with
  | Wild        -> TRef(ref None)
  | Appl(t1,t2) -> Appl(add_refs t1, add_refs t2)
  | _           -> t

(** [break_prod] is given a nested product term (potentially with no products)
    and it unbinds all the the quantified variables. It returns the  term with
    the free variables and the list of variables that  were  unbound, so  that
    they can be bound to the term and substituted with the right terms. *)
let break_prod : term -> term * tvar list = fun t ->
  let rec aux : term -> tvar list -> term * tvar list = fun t vs ->
    match unfold t with
    | Prod(_,b) -> let (v,b) = Bindlib.unbind b in aux b (v::vs)
    | _         -> (t, List.rev vs)
  in aux t []

(** [match_pattern] is given a term with variables to be substituted and the
    term with which it must be unified. It does the substitutions (calling eq)
    and returns an array with the value each variable was substituted with, if
    a unification was found. It returns None, otherwise. *)
let match_pattern : to_subst -> term -> term array option = fun (xs,p) t ->
  let ts = Array.map (fun _ -> TRef(ref None)) xs in
  let p = Bindlib.msubst (Bindlib.unbox (Bindlib.bind_mvar xs (lift p))) ts in
  if Terms.eq p t then Some(Array.map unfold ts) else None

(** [find_sub] is given two terms and finds the first instance of  the  second
    term in the first, if one exists, and returns the substitution giving rise
    to this instance or an empty substitution otherwise. *)
let find_sub : term -> to_subst -> term array option = fun t1 (vs,t2) ->
  let time = Time.save () in
  let rec find_sub_aux : term -> term array option = fun t1 ->
    match match_pattern (vs,t2) t1 with
    | Some sub -> Some sub
    | None     ->
      begin
          Time.restore time ;
          match unfold t1 with
          | Appl(x,y) ->
             begin
              match find_sub_aux x with
              | Some sub -> Some sub
              | None     -> Time.restore time ; find_sub_aux y
             end
          | _ -> None
      end
  in find_sub_aux t1

(** [make_pat] is given a term [g] and a pattern [p],  containing  TRef's that
    point to None. We try to match [p] with some subterm of [g] using Terms.eq
    so that after the call [p] has been updated to be syntactically identical
    to the subterm it matched with. *)
let make_pat : term -> term -> term option = fun g p ->
  let time = Time.save() in
  let rec make_pat_aux : term -> term option = fun g ->
    if Terms.eq g p then Some p else
      begin
      Time.restore time ;
      match unfold g with
      | Appl(x,y) ->
          begin
          match make_pat_aux x with
          | Some p -> Some p
          | None   -> Time.restore time ; make_pat_aux y
          end
      | _ -> None
      end
  in make_pat_aux g

(** [match_box t1 t2] produces a box that abstracts away all the occurences
    of the term [t1] in the term [t2].  We require that [t2] does not contain
    products, abstraction, metavariables, or other awkward terms. *)
let match_box : term * tvar -> term -> tbox =  fun (t1,x) t2 ->
  (* NOTE we lift to the bindbox while matching (for efficiency). *)
  let rec lift_subst : term -> tbox = fun t ->
    if Terms.eq t1 t then _Vari x else
    match unfold t with
    | Vari(y)     -> _Vari y
    | Type        -> _Type
    | Kind        -> _Kind
    | Symb(s)     -> _Symb s
    | Appl(t,u)   -> _Appl (lift_subst t) (lift_subst u)
    (* For now, we fail on products, abstractions and metavariables. *)
    | Prod(_)     -> fatal_no_pos "Cannot rewrite under products."
    | Abst(_)     -> fatal_no_pos "Cannot rewrite under abstractions."
    | Meta(_)     -> fatal_no_pos "Cannot rewrite metavariables."
    (* Forbidden cases. *)
    | Patt(_,_,_) -> assert false
    | TEnv(_,_)   -> assert false
    | Wild        -> assert false
    | TRef(_)     -> assert false
  in
  lift_subst t2

(** [rewrite ps po t] rewrites according to the equality proved by [t] in  the
    current goal of [ps].  The term [t] should have a type corresponding to an
    equality. Every occurrence of the first instance of the left-hand side  is
    replaced by the right-hand side of the obtained proof. It also handles the
    full set of SSReflect patterns. *)
let rewrite : Proof.t -> rw_patt option -> term -> term = fun ps p t ->
  (* Obtain the required symbols from the current signature. *)
  (* FIXME use a parametric notion of equality. *)
  let sign = Sign.current_sign () in
  let find_sym : string -> sym = fun name ->
    try Sign.find sign name with Not_found ->
    fatal_no_pos "Current signature does not define symbol [%s]." name
  in
  let sign_P  = find_sym "P"  in
  let sign_T  = find_sym "T"  in
  let sign_eq = find_sym "eq" in
  let sign_eqind = find_sym "eqind" in

  (* Get the focused goal, and related data. *)
  let g =
    try List.hd Proof.(ps.proof_goals) with Failure _  ->
    fatal_no_pos "No remaining goals..."
  in

  (* Infer the type of [t] (the argument given to the tactic). *)
  let g_ctxt = Ctxt.of_env (fst (Goal.get_type g)) in
  let t_type =
    match Solve.infer g_ctxt t with
    | Some(a) -> a
    | None    ->
        fatal_no_pos "Cannot infer the type of [%a] (given to rewrite)." pp t
  in
  (* Check that the type of [t] is of the form “P (Eq a l r)”. and return the
   * parameters. *)
  let (t_type, vars) = break_prod t_type in

  let (a, l, r)  =
    match get_args t_type with
    | (p,[eq]) when is_symb sign_P p ->
        begin
          match get_args eq with
          | (e,[a;l;r]) when is_symb sign_eq e -> (a, l, r)
          | _                                  ->
              fatal_no_pos "Rewrite expected equality type (found [%a])." pp t
        end
    | _                              ->
        fatal_no_pos "Rewrite expected equality type (found [%a])." pp t
  in

  let t_args = add_args t (List.map mkfree vars) in
  let triple = Bindlib.box_triple (lift t_args) (lift l) (lift r)  in
  let bound = Bindlib.unbox (Bindlib.bind_mvar (Array.of_list vars) triple) in

  (* Extract the term from the goal type (get “t” from “P t”). *)
  let g_term =
    match get_args (snd (Goal.get_type g)) with
    | (p, [t]) when is_symb sign_P p -> t
    | _                              ->
        fatal_no_pos "Rewrite expects a goal of the form “P t” (found [%a])."
          pp (snd (Goal.get_type g))
  in
  (* Distinguish between possible paterns. *)
  let (pred_bind, new_term, t, l, r) =
    match p with
    | None                         ->
        begin
        match find_sub g_term  ((Array.of_list vars),l) with
        | None       ->
          fatal_no_pos "No subterm of [%a] matches [%a]." pp g_term pp l
        | Some sigma ->
            let (t,l,r) = Bindlib.msubst bound sigma in
            let x = Bindlib.new_var mkfree "X" in
            let pred = match_box (l,x) g_term in
            let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred) in
            (pred_bind, Bindlib.subst pred_bind r, t, l, r)
        end
    (* Basic patterns. *)
    | Some(RW_Term(p)            ) ->
        begin
        (* Substitute every wildcard in [p] with a new TRef. *)
        let p_refs = add_refs p in

        (* Try to match this new p with some subterm of the goal. *)
        match make_pat g_term p_refs with
        | None   ->
          fatal_no_pos "No subterm of [%a] matches [%a]." pp g_term pp p
        | Some p ->
        (* Here [p] no longer has any TRefs and we try to match p with l, to
         * get the substitution [sigma]. *)
            match match_pattern (Array.of_list vars,l) p with
            | None       ->
                fatal_no_pos "The pattern [%a] does not match [%a]." pp p pp l
            | Some sigma ->
                let (t,l,r) = Bindlib.msubst bound sigma in
                let x = Bindlib.new_var mkfree "X" in
                let pred = match_box (l,x) g_term in
                let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred) in
                (pred_bind, Bindlib.subst pred_bind r, t, l, r)
        end
    | Some(RW_IdInTerm(p)      ) ->
        (* The code here works as follows: *)
        (* 1 - Try to match [p] with some subterm of the goal. *)
        (* 2 - If we succeed we do two things, we first replace [id] with its
               value, [id_val], the value matched to get [pat_l] and  try to
               match [id_val] with the LHS of the lemma. *)
        (* 3 - If we succeed we create the "RHS" of the pattern, which is [p]
               with [sigma r] in place of [id]. *)
        (* 4 - We then construct the following binders:
               a - [pred_bind_l] : A binder with a new variable replacing each
                   occurrence of [pat_l] in g_term.
               b - [pred_bind] : A binder with a new variable only replacing
                   the subterms where a rewrite happens. *)
        (* 5 - The new goal [new_term] is constructed by substituting [r_pat]
               in [pred_bind_l]. *)
        begin
        let (id,p) = Bindlib.unbind p in
        let p_refs = add_refs p in
        match find_sub g_term ((Array.of_list [id]),p_refs)  with
        | None       ->
            fatal_no_pos "The pattern [%a] does not match [%a]." pp p pp l
        | Some id_val ->
            let id_val = id_val.(0) in
            let pat = Bindlib.unbox (Bindlib.bind_var id (lift p_refs)) in
            (* The LHS of the pattern, i.e. the pattern with id replaced by *)
            (* id_val. *)
            let pat_l = Bindlib.subst pat id_val in

            (* This must match with the LHS of the equality proof we use. *)
            match match_pattern (Array.of_list vars,l) id_val with
            | None       ->
                fatal_no_pos
                "The value of [%s], [%a], in [%a] does not match [%a]."
                  (Bindlib.name_of id) pp id_val pp p pp l
            | Some sigma ->
                (* Build t, l, using the substitution we found. Note that r  *)
                (* corresponds to the value we get by applying rewrite to *)
                (* id val. *)
                let (t,l,r) = Bindlib.msubst bound sigma in

                (* The RHS of the pattern, i.e. the pattern with id replaced *)
                (* by the result of rewriting id_val. *)
                let pat_r = Bindlib.subst pat r in

                (* Build the predicate, identifying all occurrences of pat_l *)
                (* substituting them, first with pat_r, for the new goal and *)
                (* then with l_x for the lambda term. *)
                let x = Bindlib.new_var mkfree "X" in
                let pred_l = match_box (pat_l,x) g_term in
                let pred_bind_l = Bindlib.unbox (Bindlib.bind_var x pred_l) in

                (* This will be the new goal. *)
                let new_term = Bindlib.subst pred_bind_l pat_r in

                (* [l_x] is the pattern with [id] replaced by the variable X *)
                (* that we use for building the predicate. *)
                let l_x = Bindlib.subst pat (Vari(x)) in
                let pred = Bindlib.unbox (Bindlib.bind_var x pred_l) in
                let pred_box = lift (Bindlib.subst pred l_x) in
                let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred_box) in

                (pred_bind, new_term, t, l, r)
        end

    (* Combinational patterns. *)
    | Some(RW_TermInIdInTerm(s,p)) ->
        (* This pattern combines the previous. First we identify the subterm of
           [g_term] that matches with [p], where [p] contains an identifier.
           Once we have the value that the identifier in [p] has been matched
           to we find a subterm of it that matches with [s].
           Then in all occurrences of the first instance of [p] in [g_term] we
           rewrite all occurrences of the first instance of [s] in the subterm
           of [p] that was matched with the identifier. *)
        begin
        let (id,p) = Bindlib.unbind p in
        let p_refs = add_refs p in
        match find_sub g_term ((Array.of_list [id]),p_refs) with
        | None        ->
            fatal_no_pos "The pattern [%a] does not match [%a]." pp p pp l
        | Some id_val ->
            (* Once we get the value of id, we work with that as our main term
               since this is where s will appear and will be substituted in. *)
            let id_val = id_val.(0) in
            (* [pat] is the full value of the pattern, with the wildcards now
               replaced by subterms of the goal and [id]. *)
            let pat = Bindlib.unbox (Bindlib.bind_var id (lift p_refs)) in
            let pat_l = Bindlib.subst pat id_val in

            (* We then try to match the wildcards in [s] with subterms of
               [id_val]. *)
            let s_refs = add_refs s in
            match make_pat id_val s_refs with
            | None   ->
                fatal_no_pos
                "The value of [%s], [%a], in [%a] does not match [%a]."
                  (Bindlib.name_of id) pp id_val pp p pp s
            | Some s ->
                (* Now we must match s, which no longer contains any TRef's
                   with the LHS of the lemma,*)
                begin
                  match match_pattern (Array.of_list vars,l) s with
                  | None       ->
                      fatal_no_pos "The term [%a] does not match the LHS [%a]"
                          pp s pp l
                  | Some sigma ->
                      begin
                      let (t,l,r) = Bindlib.msubst bound sigma in

                      let x = Bindlib.new_var mkfree "X" in

                      (* First we work in [id_val], that is, we substitute all
                         the occurrences of [l] in [id_val] with [r]. *)
                      let id_box = match_box (l,x) id_val in
                      let id_bind = Bindlib.bind_var x id_box in

                      (* [new_id] is the value of [id_val] with [l] replaced
                         by [r] and [id_x] is the value of [id_val] with the
                         free variable [x]. *)
                      let new_id = Bindlib.(subst (unbox id_bind) r) in
                      let id_x = Bindlib.(subst(unbox id_bind) (Vari(x))) in

                      (* Then we replace in pat_l all occurrences of [id]
                         with [new_id]. *)
                      let pat_r = Bindlib.subst pat new_id in

                      (* To get the new goal we replace all occurrences of
                        [pat_l] in [g_term] with [pat_r]. *)
                      let pred_l = match_box (pat_l, x) g_term in
                      let pred_bind_l = Bindlib.(unbox (bind_var x pred_l)) in

                      (* [new_term] is the type of the new goal meta. *)
                      let new_term = Bindlib.subst pred_bind_l pat_r in

                      (* Finally we need to build the predicate. First we build
                         the term l_x, in a few steps. We substitute all the
                         rewrites in new_id with x and we repeat some steps. *)
                      let l_x = Bindlib.subst pat id_x in

                      (* The last step to build the predicate is to substitute
                         [l_x] everywhere we find [pat_l] and bind that x. *)
                      let pred = Bindlib.subst pred_bind_l l_x in
                      let pred_bind = Bindlib.bind_var x (lift pred) in
                      (Bindlib.unbox pred_bind, new_term, t, l, r)
                      end
                end
        end
    | Some(RW_TermAsIdInTerm(s,p)) ->
        (* In this pattern we have essentially a let clause. We first match the
           value of [pat] with some subeterm of the goal and then we rewrtie in
           each occurence [id]. *)
        begin
        let (id,pat) = Bindlib.unbind p in
        let s = add_refs s in
        let p_s = Bindlib.subst p s in
        (* Try to match p[s/id] with a subterm of the goal. *)
        match make_pat g_term (add_refs p_s) with
        | None   ->
            fatal_no_pos "No subterm of [%a] matches the pattern [%a]"
                pp g_term pp p_s
        | Some p ->
            let pat_refs = add_refs pat in
            (* Here we have already asserted tat an instance of p[s/id] exists
               so we know that this will match something. The step is repeated
               in order to get the value of [id]. *)
            match match_pattern (Array.of_list [id], pat_refs) p with
            | None   -> assert false
            | Some sub ->
                let id_val = sub.(0) in
                (* This part of the term-building is similar to the previous
                   case, as we are essentially rebuilding a term, with some
                   subterms that are replaced by new ones. *)
                match match_pattern (Array.of_list vars, l) id_val with
                | None       ->
                    fatal_no_pos
                    "The value of X, [%a], does not match the LHS, [%a]"
                    pp id_val pp l
                | Some sigma ->
                    let (t,l,r) = Bindlib.msubst bound sigma in
                    let x = Bindlib.new_var mkfree "X" in

                    (* Now to do some term building. *)
                    let p_box = match_box (l,x) p in
                    let p_x = Bindlib.(unbox (bind_var x p_box)) in

                    let p_r = Bindlib.subst p_x r in

                    let pred = match_box (p,x) g_term in
                    let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred) in

                    let new_term = Bindlib.subst pred_bind p_r in

                    let p_x = Bindlib.subst p_x (Vari(x)) in
                    let pred_box = lift (Bindlib.subst pred_bind p_x) in
                    let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred_box) in

                    (pred_bind, new_term, t, l, r)
        end
    (* Nested patterns. *)
    | Some(RW_InTerm(p)          ) ->
        begin
        (* Substitute every wildcard in [p] with a new TRef. *)
        let p_refs = add_refs p in

        (* Try to match this new p with some subterm of the goal. *)
        match make_pat g_term p_refs with
        | None   ->
            fatal_no_pos "No subterm of [%a] matches [%a]." pp g_term pp p
        | Some p ->
        (* Here [p] no longer has any TRefs and we try to find a subterm of [p]
         * with [l], to get the substitution [sigma]. *)
            match find_sub p ((Array.of_list vars),l) with
            | None       ->
                fatal_no_pos "No subterm of the pattern [%a] matches [%a]."
                    pp p pp l
            | Some sigma ->
                let (t,l,r) = Bindlib.msubst bound sigma in

                let x = Bindlib.new_var mkfree "X" in
                let p_x = Bindlib.(unbox (bind_var x (match_box (l,x) p))) in
                let p_r = Bindlib.subst p_x r in

                let pred = match_box (p,x) g_term in
                let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred) in

                let new_term = Bindlib.subst pred_bind p_r in

                let p_x = Bindlib.subst p_x (Vari(x)) in
                let pred_box = lift (Bindlib.subst pred_bind p_x) in
                let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred_box) in

                (pred_bind, new_term, t, l, r)
        end
    | Some(RW_InIdInTerm(p)      ) ->
        (* This is very similar to the RW_IdInTerm case, with a few minor
           changes. Instead of trying to match [id_val] with [l] we try to
           match a subterm of id_val with [l] and then we rewrite this subterm.
           So we just change the way we construct a [pat_r]. *)
        begin
        let (id,p) = Bindlib.unbind p in
        let p_refs = add_refs p in
        match find_sub g_term ((Array.of_list [id]),p_refs)  with
        | None       ->
            fatal_no_pos "The pattern [%a] does not match [%a]." pp p pp g_term
        | Some id_val ->
            let id_val = id_val.(0) in
            let pat = Bindlib.unbox (Bindlib.bind_var id (lift p_refs)) in
            let pat_l = Bindlib.subst pat id_val in
            match find_sub id_val ((Array.of_list vars),l) with
            | None       ->
                fatal_no_pos
                "The value of [%s], [%a], in [%a] does not match [%a]."
                  (Bindlib.name_of id) pp id_val pp p pp l
            | Some sigma ->
                let (t,l,r) = Bindlib.msubst bound sigma in

                (* Start building the term. *)
                let x = Bindlib.new_var mkfree "X" in

                (* Rewrite in id. *)
                let id_box = match_box (l, x) id_val in
                let id_bind = Bindlib.(unbox (bind_var x id_box)) in
                let id_val = Bindlib.subst id_bind r in

                let id_x = Bindlib.subst id_bind (Vari(x)) in

                (* The new RHS of the pattern is obtained by rewriting inside
                   id_val. *)
                let r_val = Bindlib.subst pat id_val in

                let pred_l = match_box (pat_l, x) g_term in
                let pred_bind_l = Bindlib.unbox (Bindlib.bind_var x pred_l) in

                let new_term = Bindlib.subst pred_bind_l r_val in

                let l_x = Bindlib.subst pat id_x in

                let pred = Bindlib.unbox (Bindlib.bind_var x pred_l) in
                let pred_box = lift (Bindlib.subst pred l_x) in
                let pred_bind = Bindlib.unbox (Bindlib.bind_var x pred_box) in

                (pred_bind, new_term, t, l, r)
        end
  in

  let pred = Abst(Appl(Symb(sign_T), a), pred_bind) in

  (* Construct the new goal and its type. *)
  let goal_type = Appl(Symb(sign_P), new_term) in
  let goal_term = Ctxt.make_meta g_ctxt goal_type in

  (* Build the final term produced by the tactic, and check its type. *)
  let term = add_args (Symb(sign_eqind)) [a; l; r; t; pred; goal_term] in

  if not (Solve.check g_ctxt term (snd (Goal.get_type g))) then
    begin
      match Solve.infer g_ctxt term with
      | Some(a) ->
          fatal_no_pos "The term produced by rewrite has type [%a], not [%a]."
            pp (Eval.snf a) pp (snd (Goal.get_type g))
      | None    ->
          fatal_no_pos "The term [%a] produced by rewrite is not typable."
            pp term
    end;

  (* Debugging data to the log. *)
  log_rewr "Rewriting with:";
  log_rewr "  goal           = [%a]" pp (snd (Goal.get_type g));
  log_rewr "  equality proof = [%a]" pp t;
  log_rewr "  equality type  = [%a]" pp t_type;
  log_rewr "  equality LHS   = [%a]" pp l;
  log_rewr "  equality RHS   = [%a]" pp r;
  log_rewr "  pred           = [%a]" pp pred;
  log_rewr "  new goal       = [%a]" pp goal_type;
  log_rewr "  produced term  = [%a]" pp term;

  (* Return the proof-term. *)
  term
