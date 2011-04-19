open Batteries
open Utils
open Map
open Cabs
open Cabsvisit
open Difftypes
open Cabswalker
open Convert

let lmapi = List.mapi

let standardize_diff children1 patch info =
  (* FIXME: debug the insertion of REPLACE edit actions since I haven't checked it recently! *)
  (* First, reconstruct insertions so that full trees are constructed *)
  let parent_ht = hcreate 10 in
  let parent_add parent edit = 
	let old = ht_find parent_ht parent (fun _ -> []) in
	  hrep parent_ht parent (edit :: old)
  in
  let moi =
	lfoldl
	  (fun map ->
		fun (enum,edit) ->
			match edit with
			| InsertTreeNode(tn,pos) -> parent_add (-1) edit; Map.add (tn.id,pos) (-1,enum) map
			| InsertDefinition(def,par,pos,_) -> parent_add par edit; Map.add (def.id,pos) (par,enum) map
			| InsertStatement(stmt,par,pos,_) -> parent_add par edit; Map.add (stmt.id,pos) (par,enum) map
			| InsertExpression(exp,par,pos,_) -> parent_add par edit; Map.add (exp.id,pos) (par,enum) map
			| _ -> map
	  ) Map.empty patch in
  let rio_ht = hcreate 10 in
  let rec recon_edit = function
	| InsertTreeNode(tn,par) -> InsertTreeNode(recon_tn (fst (hfind info.tn_ht tn.id)), par)
	| InsertDefinition(def,par,a,b) -> InsertDefinition(recon_def (fst (hfind info.def_ht def.id)),par,a,b)
	| InsertStatement(stmt,par,a,b) -> InsertStatement(recon_stmt (fst (hfind info.stmt_ht stmt.id)),par,a,b)
	| InsertExpression(exp,par,a,b) -> InsertExpression(recon_exp (fst (hfind info.exp_ht exp.id)),par,a,b)
	| e -> e
  and recon_tn tn =
	let should_d = should_d tn.id in
	let should_s = should_s tn.id in
	let should_e = should_e tn.id in
	  if hmem parent_ht tn.id then begin
		{tn with node = NODE(match dn tn with
		| Globals(dlist) -> Globals(lmapi (fun index -> fun def -> should_d index def) dlist)
		| Stmts(slist) -> Stmts(lmapi (fun index -> fun stmt -> should_s index stmt) slist)
		| Exps(elist) -> Exps(lmapi (fun index -> fun exp -> should_e index exp) elist)) }
	  end else snd (hfind info.tn_ht tn.id)
  and recon_def def = 
	let should_d = should_d def.id in
	let should_e = should_e def.id in
	  if hmem parent_ht def.id then begin
		let node = 
		  match dn def with
			FUNDEF(sn,b,l1,l2) -> FUNDEF(recon_sn sn, recon_block def.id b,l1,l2)
		  | DECDEF(ing,loc) -> DECDEF(recon_ing ing,loc)
		  | TYPEDEF(ng,loc) -> TYPEDEF(recon_ng ng,loc)
		  | ONLYTYPEDEF(spec,loc) -> ONLYTYPEDEF(recon_spec spec,loc)
		  | PRAGMA(e1,loc) -> PRAGMA(should_e 0 e1,loc)
		  | LINKAGE(str,loc,dlist) ->
			LINKAGE(str,loc,lmapi (fun i -> fun def -> should_d i def) dlist)
		  | d -> d
		in
		  { def with node = NODE(node) }
	  end else snd (hfind info.def_ht def.id)
  and recon_stmt stmt = 
	let should_d = should_d stmt.id in
	let should_s = should_s stmt.id in
	let should_e = should_e stmt.id in
	  if hmem parent_ht stmt.id then begin
		let node = 
		  match dn stmt with
		  | COMPUTATION(e1,loc) -> COMPUTATION(should_e 0 e1,loc)
		  | BLOCK(b,loc) -> BLOCK(recon_block stmt.id b ,loc)
		  | SEQUENCE(s1,s2,loc) -> SEQUENCE(should_s 0 s1,should_s 1 s2,loc)
		  | IF(e1,s1,s2,loc) -> IF(should_e 0 e1,should_s 1 s1,should_s 2 s2,loc)
		  | WHILE(e1,s1,loc) -> WHILE(should_e 0 e1, should_s 1 s1, loc)
		  | DOWHILE(e1,s1,loc) -> DOWHILE(should_e 0 e1,should_s 1 s1, loc)
		  | FOR(fc,e1,e2,s1,loc) -> FOR(recon_fc fc, should_e 1 e1,should_e 2 e2, should_s 3 s1,loc)
		  | RETURN(e1,loc) -> RETURN(should_e 0 e1,loc)
		  | SWITCH(e1,s1,loc) -> SWITCH(should_e 0 e1,should_s 1 s1,loc)
		  | CASE(e1,s1,loc) -> CASE(should_e 0 e1,should_s 1 s1,loc)
		  | CASERANGE(e1,e2,s1,loc) -> CASERANGE(should_e 0 e1,should_e 1 e2,should_s 2 s1,loc)
		  | DEFAULT(s1,loc) -> DEFAULT(should_s 0 s1,loc)
		  | LABEL(str,s1,loc) -> LABEL(str,should_s 1 s1,loc)
		  | COMPGOTO(e1,loc) -> COMPGOTO(should_e 0 e1,loc)
		  | DEFINITION(d) -> DEFINITION(should_d 0 d)
		  | TRY_EXCEPT(b1,e1,b2,loc) -> TRY_EXCEPT(recon_block stmt.id b1,should_e 1 e1,recon_block stmt.id b2,loc)
		  | TRY_FINALLY(b1,b2,loc) -> TRY_FINALLY(recon_block stmt.id b1,recon_block stmt.id b2,loc)
		  | s -> s
		in
		  { stmt with node = NODE(node) }
	  end else snd (hfind info.stmt_ht stmt.id)
  and recon_exp exp = 
	let should_e = should_e exp.id in
	  if hmem parent_ht exp.id then begin
		let node = 
		  match dn exp with
		  | UNARY(uop,e1) -> UNARY(uop,should_e 1 e1)
		  | BINARY(bop,e1,e2) -> BINARY(bop,should_e 1 e1, should_e 2 e2)
		  | QUESTION(e1,e2,e3) -> QUESTION(should_e 0 e1, should_e 1 e2, should_e 2 e3)
		  | CAST((spec,dt),ie) -> CAST((recon_spec spec,recon_dt dt),recon_ie ie)
		  | CALL(e1,elist) -> CALL(should_e 0 e1, lmapi (fun i -> fun exp -> should_e (i+1) exp) elist)
		  | COMMA(elist) -> COMMA(lmapi (fun i -> fun exp -> should_e i exp) elist)
		  | PAREN(e1) -> PAREN(should_e 0 e1)
		  | EXPR_SIZEOF(e1) -> EXPR_SIZEOF(should_e 0 e1)
		  | TYPE_SIZEOF(spec,dt) -> TYPE_SIZEOF(recon_spec spec,recon_dt dt)
		  | EXPR_ALIGNOF(e1) -> EXPR_ALIGNOF(should_e 0 e1)
		  | TYPE_ALIGNOF(spec,dt) -> TYPE_ALIGNOF(recon_spec spec,recon_dt dt)
		  | INDEX(e1,e2) -> INDEX(should_e 0 e1, should_e 1 e2)
		  | MEMBEROF(e1,str) -> MEMBEROF(should_e 0 e1,str)
		  | MEMBEROFPTR(e1,str) -> MEMBEROFPTR(should_e 0 e1,str)
		  | GNU_BODY(b) -> GNU_BODY(recon_block exp.id b)
		  | e -> e
		in 
		  { exp with node=NODE(node) }
	  end else snd (hfind info.exp_ht exp.id)
  and recon_sn (spec,name) = recon_spec spec, recon_name name
  and recon_spec spec = lmap recon_se spec 
  and recon_name (str,dt,attrs,loc) = str,recon_dt dt,lmap recon_attr attrs,loc
  and recon_block parent block =
	{ blabels = block.blabels; battrs = lmap recon_attr block.battrs; bstmts = lmapi (fun i -> fun stmt -> should_s parent i stmt) block.bstmts }
  and recon_ing (spec,ins) = recon_spec spec,lmap recon_in ins
  and recon_in (name,ie) = recon_name name,recon_ie ie
  and recon_ng (spec,names) = recon_spec spec,lmap recon_name names
  and recon_fc = function
	| FC_EXP(e1) -> FC_EXP(recon_exp e1)
	| FC_DECL(d1) -> FC_DECL(recon_def d1)
  and recon_dt = function
	| PARENTYPE(as1,dt,as2) -> PARENTYPE(lmap recon_attr as1,recon_dt dt, lmap recon_attr as2)
	| ARRAY(dt,attrs,e1) -> ARRAY(recon_dt dt, lmap recon_attr attrs, recon_exp e1)
	| PTR(attrs,dt) -> PTR(lmap recon_attr attrs, recon_dt dt)
	| PROTO(dt,sns,b) -> PROTO(recon_dt dt, lmap recon_sn sns,b)
	| dt -> dt
  and recon_ie = function
	| SINGLE_INIT(e1) -> SINGLE_INIT(recon_exp e1)
	| COMPOUND_INIT(iwies) -> COMPOUND_INIT(lmap (fun (iw,ie) -> recon_iw iw,recon_ie ie) iwies)
	| ie -> ie
  and recon_iw = function
	| INFIELD_INIT(str,iw) -> INFIELD_INIT(str,recon_iw iw)
	| ATINDEX_INIT(e1,iw) -> ATINDEX_INIT(recon_exp e1,recon_iw iw) 
	| ATINDEXRANGE_INIT(e1,e2) -> ATINDEXRANGE_INIT(recon_exp e1, recon_exp e2)
	| iw -> iw
  and recon_se = function
	| SpecAttr(a) -> SpecAttr(recon_attr a)
	| SpecType(ts) -> SpecType(recon_ts ts)
	| se -> se
  and recon_attr (str,elist) = str,lmap recon_exp elist
  and recon_ts = function
	| Tstruct(str,Some(fgs),attrs) -> Tstruct(str,Some(lmap recon_fg fgs),lmap recon_attr attrs)
	| Tstruct(str,None,attrs) -> Tstruct(str,None,lmap recon_attr attrs)
	| Tunion(str,Some(fgs), attrs) -> Tunion(str,Some(lmap recon_fg fgs), lmap recon_attr attrs)
	| Tunion(str,None, attrs) -> Tunion(str,None, lmap recon_attr attrs)
	| Tenum(str,Some(eis),attrs) -> Tenum(str,Some(lmap recon_ei eis), lmap recon_attr attrs) 
	| Tenum(str,None,attrs) -> Tenum(str,None,lmap recon_attr attrs)
	| TtypeofE(e1) -> TtypeofE(recon_exp e1)
	| TtypeofT(spec,dt) -> TtypeofT(recon_spec spec,recon_dt dt)
	| ts -> ts
  and recon_fg (spec,lst) =
	recon_spec spec,
	lmap (fun (n,eno) -> recon_name n, match eno with None -> None | Some(e) -> Some(recon_exp e)) lst
  and recon_ei (str,e,loc) = str,recon_exp e,loc
  and should_e par pos e1 =
	if (Map.mem (e1.id,pos) moi) &&
	  (fst (Map.find (e1.id,pos) moi)) == par then begin
		let _,enum = Map.find (e1.id,pos) moi in
		  hadd rio_ht enum (); recon_exp e1
	  end else snd (hfind info.exp_ht e1.id)
  and should_s par pos s1 =
	if (Map.mem (s1.id,pos) moi) &&
	  (fst (Map.find (s1.id,pos) moi) == par) then 
	  begin 
		let _,enum = Map.find (s1.id,pos) moi in
		hadd rio_ht enum (); recon_stmt s1
	  end else snd (hfind info.stmt_ht s1.id)
  and should_d par pos d1 =
	if (Map.mem (d1.id,pos) moi) && 
	  (fst (Map.find (d1.id,pos) moi)) == par then
	  begin
		let _,enum = Map.find (d1.id,pos) moi in
		  hadd rio_ht enum (); recon_def d1
	  end else snd (hfind info.def_ht d1.id)
  in
  let patch = lmap (fun (num,edit) -> num,recon_edit edit) patch in 
  let patch = lfilt (fun (num,edit) -> not (hmem rio_ht num)) patch in
  let deleted = hcreate 10 in
  let moves = hcreate 10 in
	liter
	  (fun (_,x) -> 
		match x with 
		| MoveExpression _
		| MoveStatement _ 
		| MoveDefinition _ -> hadd moves x ()
		| DeleteExp(n,_,_) -> hadd deleted n.id x
		| DeleteStmt(n,_,_) -> hadd deleted n.id x
		| DeleteDef(n,_,_) -> hadd deleted n.id x
		| DeleteTN(n,_,_) -> hadd deleted n.id x
		| _ -> ()) patch;
	let all_moves = List.of_enum (Hashtbl.keys moves) in
	let removed_ops = hcreate 10 in
	let exists_ht = hcreate 10 in
	  liter
		(fun move ->
		  match move with
		  | MoveExpression(exp1,move_to1,move_from1,position1,_,_) ->
			let exp_str1 = exp_str exp1 in
			let exists_another = 
			  List.exists
				(fun move -> 
				  match move with 
				  | MoveExpression(exp2,move_to2,move_from2,position2,_,_) ->
					let exp_str2 = exp_str exp2 in
					  exp1.id <> exp2.id && exp_str1 = exp_str2 && move_to1 == move_from2
				  | _ -> false) all_moves in
			  if exists_another then hadd exists_ht move ();
		  | MoveStatement(stmt1,move_to1,move_from1,position1,_,_) ->
			let stmt_str1 = stmt_str stmt1 in
			let exists_another = 
			  List.exists
				(fun move -> 
				  match move with 
				  | MoveStatement(stmt2,move_to2,move_from2,position2,_,_) ->
					let stmt_str2 = stmt_str stmt2 in
					  stmt1.id <> stmt2.id && stmt_str1 = stmt_str2 && move_to1 == move_from2
				  | _ -> false) all_moves in
			  if exists_another then hadd exists_ht move ();
		  | _ -> ()) all_moves;
	  let patch = lfilt (fun (_,x) -> not (hmem exists_ht x)) patch in
	  let is_really_a_replace parent position =
		try
		  let children = Map.find parent children1 in
		  let index = ref (-1) in 
			lfoldl
			  (fun is_rep ->
				fun ele -> 
				  incr index;
				  if hmem deleted ele && 
					position <> -1 && 
					(!index - 1 == position || !index + 1 == position || !index == position) then begin
					  let op = hfind deleted ele in 
						hadd removed_ops op ele; (true,op)
					end else is_rep
			  ) (false,(DeleteTN(nd(Stmts([])),-1,PTREE))) children
		with Not_found -> false,DeleteTN(nd(Stmts([])),-1,PTREE)
	  in
	  let make_replace operation replacing = 
		match operation,replacing with
		| InsertTreeNode(tn1,pos),DeleteTN(tn2,_,_)
		| ReorderTreeNode(tn1,pos,_),DeleteTN(tn2,_,_) ->
		  ReplaceTreeNode(tn1,tn2,pos)
		| InsertDefinition(def1,parent1,position,t1),DeleteDef(def2,_,_)
		| MoveDefinition(def1,parent1,_,position,t1,_),DeleteDef(def2,_,_) ->
		  ReplaceDefinition(def1,def2,parent1,position,t1)
		| InsertStatement(stmt1,parent,position,t1), DeleteStmt(stmt2,_,_)
		| MoveStatement(stmt1,parent,_,position,t1,_), DeleteStmt(stmt2,_,_) ->
		  ReplaceStatement(stmt1,stmt2,parent,position,t1)
		| InsertExpression(exp1,parent,position,t1), DeleteExp(exp2,_,_)
		| MoveExpression(exp1,parent,_,position,t1,_), DeleteExp(exp2,_,_) -> 
		  ReplaceExpression(exp1,exp2,parent,position,t1)
		| _ -> failwith "Unexpected operation in make_replace" 
	  in
(*	  let patch = 
		lmap (fun (id,operation) -> 
		  let op' = 
			match operation with
			| InsertTreeNode(_,pos) ->
			  let is_replace,replacing = is_really_a_replace (-1) pos in
				if is_replace then make_replace operation replacing else operation
			| InsertDefinition(_,parent,position,_)
			| MoveDefinition(_,parent,_,position,_,_)
			| InsertStatement(_,parent,position,_)
			| MoveStatement(_,parent,_,position,_,_)
			| InsertExpression(_,parent,position,_)
			| MoveExpression(_,parent,_,position,_,_) -> 
			  let is_replace,replacing = is_really_a_replace parent position in
				if is_replace then make_replace operation replacing else operation
			| _ -> operation
		  in id,op') patch in *)
		lfilt (fun (_,x) -> not (hmem removed_ops x)) patch
	  
(*************************************************************************)
(* Alpha-renaming of a diff tree *)
(* NOTE: THIS IS NOT DONE, I don't think *)

(* CSpec, section 6.2.1: Scopes of identifiers:
 * 
 * there are 4 types of scopes in C: function, file, block, function
 * prototype.
 * 
 * 1) function only matters for label names.
 * 
 * 2) In general, things have file scope.
 * 
 * 3) Blocks have their own scopes.
 * 
 * 4) function prototypes have their own scope, which terminates at the
 * end of the declarator structure. *)


let a_cntr = ref 0
let new_alpha () = incr a_cntr; "a" ^ (String.of_int !a_cntr)
let alpha_tbl : (string, string) Hashtbl.t = hcreate 10
let alpha_context : string list list ref = ref []
let push_context _ = alpha_context := [] :: !alpha_context
let pop_context _ =
  match !alpha_context with
    [] -> ()
  | con::sub ->
		(alpha_context := sub;
		liter (fun name -> hrem alpha_tbl name) con)

(* note from cabsvisit.ml: "All visit methods are called in preorder!
 * (but you can use ChangeDoChildrenPost to change the order)"; I don't
 * know if this is different from the norm, so pay attention to see if
 * everything goes all foobar. *)

class alphaRename = object(self)
  inherit nopCabsVisitor

  method vblock b =
	self#vEnterScope(); ChangeDoChildrenPost(b, (fun b -> self#vExitScope(); b))

  method vvar name = 
	ht_find alpha_tbl name (fun x -> new_alpha())

  (*  method vdef def =
	  match def with
	  FUNDEF(sn,body,start,endloc) ->
	  let get_proto dtype =
	  match dtype with
	  | _ -> DoChildren*)

  method vtypespec ts = 
	match ts with
	| Tnamed(namestr) -> 
		let namestr' = ht_find alpha_tbl namestr (fun x -> new_alpha()) in
		  ChangeTo(Tnamed(namestr'))
	| _ -> DoChildren

  method vname nk spec (realname,dtype1,alist,loc) =
	let realname' = ht_find alpha_tbl realname (fun x -> new_alpha()) in
	let name' = (realname',dtype1,alist,loc) in
	  (*	  match dtype1 with
			  PROTO(dtype2,snames,ell) ->
			  ChangeDoChildrenPost(self#vEnterScope(); name'),
			  (fun name -> self#vExitScope(); name)
			  | _ -> *) ChangeDoChildrenPost(name', (fun name -> name))

  method vEnterScope () = push_context()
  method vExitScope () = pop_context()
	
end

let a_cntr = ref 0
let new_alpha () = incr a_cntr; "a" ^ (String.of_int !a_cntr)
let alpha_context : string list list ref = ref []
let push_context _ = alpha_context := [] :: !alpha_context
let pop_context _ =
  match !alpha_context with
    [] -> ()
  | con::sub ->
		(alpha_context := sub;
		liter (fun name -> hrem alpha_tbl name) con)

(* note from cabsvisit.ml: "All visit methods are called in preorder!
 * (but you can use ChangeDoChildrenPost to change the order)"; I don't
 * know if this is different from the norm, so pay attention to see if
 * everything goes all foobar. *)

(*class alphaRenameWalker  = object(self)
  inherit [(string,string) Map.t] singleCabsWalker
  (* todo: should I rename the labels? *)

  method combine one two = Map.union one two
  method default_res() = Map.empty

  method wExpression exp = 
	match (dn exp) with 
	| CONSTANT(CONST_STRING(str)) 
	| VARIABLE(str) -> 
	  if hmem alpha_tbl str then 
		Result(Map.singleton str (hfind alpha_tbl str))
	  else begin
		hadd alpha_tbl str (new_alpha());
		Result(Map.singleton str (hfind alpha_tbl str))
	  end
	| _ -> Children
	  
  method wName (str,_,_,_) = 
	CombineChildren(
	  if hmem alpha_tbl str then 
		Map.singleton str (hfind alpha_tbl str)
	  else begin
		hadd alpha_tbl str (new_alpha());
		Map.singleton str (hfind alpha_tbl str)
	  end)

  method enterScope () = push_context ()
  method exitScope () = pop_context ()

  method walkChanges (changes : changes) : (string,string) Map.t = failwith "Not implemented walkchanges in alpharenamewalker"
end*)

let renameVisit = new alphaRename 

let alpha_rename diff = 
  (* alpha rename should actually copy everything it alpha renames so that we have
	 both *)
  let diff' = copy diff in
  let rename_def def = 
	match (visitCabsDefinition renameVisit def) with
	  [def] -> def
	| _ -> failwith "Unexpected visit cabs def return in alpha rename"
  in 
  let rename_stmt stmt = 
	match (visitCabsStatement renameVisit stmt) with
	  [stmt] -> stmt
	| _ -> failwith "Unexpected visit cabs stmt return in alpha rename"
  in 
  let rename_edit_action = function
	| InsertTreeNode(tn,i) -> InsertTreeNode(visitTreeNode renameVisit tn, i)
	| ReorderTreeNode(tn,i1,i2) -> ReorderTreeNode(visitTreeNode renameVisit tn,i1,i2)
	| ReplaceTreeNode(tn1,tn2,i) -> ReplaceTreeNode(visitTreeNode renameVisit tn1, visitTreeNode renameVisit tn2,i)
	| InsertDefinition(def,i1,i2,ptyp) -> InsertDefinition(rename_def def, i1,i2,ptyp)
	| ReplaceDefinition(def1,def2,i1,i2,ptyp) -> ReplaceDefinition(rename_def def1,rename_def def2, i1,i2,ptyp)
	| MoveDefinition(def,i1,i2,i3,p1,p2) -> MoveDefinition(rename_def def, i1,i2,i3,p1,p2)
	| ReorderDefinition(def,i1,i2,i3,p) -> ReorderDefinition(rename_def def, i1,i2,i3,p)
	| InsertStatement(stmt,i1,i2,p) -> InsertStatement(rename_stmt stmt,i1,i2,p)
	| ReplaceStatement(stmt1,stmt2,i1,i2,p) -> ReplaceStatement(rename_stmt stmt1,rename_stmt stmt2, i1,i2,p)
	| MoveStatement(stmt,i1,i2,i3,p1,p2) -> MoveStatement(rename_stmt stmt, i1,i2,i3,p1,p2)
	| ReorderStatement(stmt,i1,i2,i3,p) -> ReorderStatement(rename_stmt stmt, i1,i2,i3,p)
	| InsertExpression(exp,i1,i2,p) ->
	  InsertExpression(visitCabsExpression renameVisit exp, i1,i2,p)
	| ReplaceExpression(exp1,exp2,i1,i2,p) ->
	  ReplaceExpression(visitCabsExpression renameVisit exp1,visitCabsExpression renameVisit exp2, i1,i2,p)
	| MoveExpression(exp,i1,i2,i3,p1,p2) ->
	  MoveExpression(visitCabsExpression renameVisit exp,i1,i2,i3,p1,p2)
	| ReorderExpression(exp,i1,i2,i3,p) ->
	  ReorderExpression(visitCabsExpression renameVisit exp,i1,i2,i3,p)
	| DeleteTN(tn,par,typ) -> DeleteTN(visitTreeNode renameVisit tn,par,typ)
	| DeleteDef(def,par,typ) -> DeleteDef(rename_def def,par,typ)
	| DeleteStmt(stmt,par,typ) -> DeleteStmt(stmt,par,typ)
	| DeleteExp(exp,par,typ) -> DeleteExp(visitCabsExpression renameVisit exp,par,typ)
  in
	lmap (fun (id,diff) -> id,rename_edit_action diff) diff'
