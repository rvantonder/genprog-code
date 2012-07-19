open Cil
open Pretty
open Utils
open DPGlobs

let flush_interval = ref 1
let flush_count = ref 1

(* constants for printing stuff out *)
let fprintf_va = makeVarinfo true "fprintf" (TVoid [])
let fopen_va = makeVarinfo true "fopen" (TVoid [])
let fflush_va = makeVarinfo true "fflush" (TVoid [])
let stderr_va = makeVarinfo true "_cbi_fout" (TPtr(TVoid [], []))
let fprintf = Lval((Var fprintf_va), NoOffset)
let fopen = Lval((Var fopen_va), NoOffset)
let fflush = Lval((Var fflush_va), NoOffset)
let stderr = Lval((Var stderr_va), NoOffset)

(* the schemes: *)
let do_coverage = ref false
let do_returns = ref false
let do_branches = ref false
let do_sp = ref false
let do_all = ref false

(* Hashtbl for globals *)
let global_vars = hcreate 100

(* This visitor stuff is taken from coverage and walks over the C program
 * AST and builds the hashtable that maps integers to statements. *) 

let count = ref 1 

class numToZeroVisitor = object
  inherit nopCilVisitor
  method vstmt s = s.sid <- 0 ; DoChildren
end 

class everyVisitor = object
  inherit nopCilVisitor
  method vblock b = 
    ChangeDoChildrenPost(b,(fun b ->
      let stmts = List.map (fun stmt ->
        match stmt.skind with
        | Instr([]) -> [stmt] 
        | Instr(first :: rest) -> 
            ({stmt with skind = Instr([first])}) ::
            List.map (fun instr -> mkStmtOneInstr instr ) rest 
        | other -> [ stmt ] 
      ) b.bstmts in
      let stmts = lflat stmts in
      { b with bstmts = stmts } 
    ))
end 

let my_zero = new numToZeroVisitor
let my_every = new everyVisitor

let instr_cov_ht = hcreate 4096

let can_trace s = 
  match s.skind with
  | Instr _
  | Return _  
  | If _ 
  | Loop _ 
	-> true
	  
  | Goto _ 
  | Break _ 
  | Continue _ 
  | Switch _ 
  | Block _ 
  | TryFinally _ 
  | TryExcept _ 
	-> false

let noIsVisited_ht = hcreate 100 

class numVisitor = object
  inherit nopCilVisitor

  method vstmt s = 
    if can_trace s then begin
	  s.sid <- !count;
	  let rhs = 
		let bcopy = copy s in
		let bcopy = visitCilStmt my_zero bcopy in 
		  bcopy.skind
	  in 
		hadd !coverage_ht !count rhs;
		(* the copy is because we go through and update the statements
		 * to add coverage information later *)
		(match s.skind with
		   Instr(ilist) -> 
			 liter 
			   (fun i -> 
				  if hmem instr_cov_ht i then 
					failwith "Double add to hashtable"
				  else
					hadd instr_cov_ht i !count)
			   ilist
		 | Return(Some(e),l) -> if !do_returns then hadd noIsVisited_ht s.sid ()
		 | If(_) -> if !do_branches then hadd noIsVisited_ht s.sid ()
		 | _ -> ()); 		  
		incr count
    end else begin s.sid <- 0 end; DoChildren

  method vblock b =
    ChangeDoChildrenPost(
      {b with bstmts = if b.bstmts = [] then [mkEmptyStmt ()] else b.bstmts },
      (fun b -> b))

  method vinst i = 
    if !do_sp then begin
      match i with 
		Set((h,o), e, l) 
      | Call(Some((h,o)), e, _, l) ->
		  let instr =
			match (h,o) with
			  (Var(_), _) 
			| (_, Field(_)) -> true
			| _ -> false
		  in
			if instr then
			  let num = hfind instr_cov_ht i in
				hadd noIsVisited_ht num ()
      | _ -> ()
    end; DoChildren
end 

let site = ref 0

(* creates a new site and returns the Const(str) to be passed to fprintf in the
 * instrumented program. *)

let get_next_site sinfo = 
  let count = !site in
    incr site ;
    hadd !site_ht count sinfo;
    let str = (spprintf "%d," count)^"%d\n" in 
      (count, (Const(CStr(str))))

(* NOTE: I have removed label generation here entirely; add back in by referring
   to related source code that also does this, or whatever, but it's
   complicating things and I don't need it right now *)

let flush_instr () = Call(None,fflush,[stderr],!currentLoc)
let make_printf_instr args = Call(None,fprintf,(stderr::args),!currentLoc)

let make_printf_instrs do_flush args =
  let printf_instr = make_printf_instr args in
    if do_flush then begin
	  if !flush_count == !flush_interval then
		begin
		  flush_count := 1;
		  mkStmt(Instr([printf_instr;flush_instr()]))
		end
	  else 
		begin 
		  incr flush_count;
		  mkStmt(Instr([printf_instr])) 
		end
    end else 
	  mkStmt(Instr([printf_instr]))

class instrumentVisitor = object(self)
  inherit nopCilVisitor
    
  val local_vars = hcreate 100

  method print_vars lhs rhs sid = (* lval and rvals are exps *)
    let sinfo = (Scalar_pairs((!currentLoc,sid,lhs,!do_coverage),[sid])) in
    let count,str = get_next_site sinfo in
      (* this code contains a tiny optimization: if this variable is being set to
       * that variable, no need to compute comparisons between them *) 
      
    let rec getname exp = 
	  let rec getoffset o =
		match o with
		  NoOffset -> ""
		| Field(fi, o) -> "." ^ fi.fname ^ (getoffset o)
		| Index(_) -> "[sub]" 
	  in
		match exp with 
		| Lval(Var(vi), o) -> vi.vname ^ (getoffset o)
		| Lval(Mem(e), o) ->
			let memstr = Pretty.sprint 80 (d_exp () e) in
			  memstr ^ (getoffset o)
		| CastE(t, e) -> getname e
		| _ -> ""
    in
    let lname,rname = getname lhs, getname rhs in
    let ltype = typeOf lhs in

    let comparable rhs =
	  let rtype = typeOf rhs in
		(* can we compare these types?  If so, get the appropriate casts! *)
	  let lhs_pointer, rhs_pointer = (isPointerType ltype), (isPointerType rtype) in
	  let lhs_array, rhs_array = (isArrayType ltype), (isArrayType rtype) in
	  let lhs_arith, rhs_arith = (isArithmeticType ltype), (isArithmeticType rtype) in
	  let lhs_integ, rhs_integ = (isIntegralType ltype), (isIntegralType rtype) in
		(lhs_pointer || lhs_array || lhs_arith || lhs_integ) &&
		  (rhs_pointer || rhs_array || rhs_arith || rhs_integ)
    in
	  
    let print_one_var strpart var =
	  let cast_to_ULL va = mkCast va (TInt(IULong,[])) in
	  let format_str lval = 
		let typ = typeOf lval in
		  if (isPointerType typ) || (isArrayType typ) then ("%u", (cast_to_ULL lval))
		  else if (isIntegralType typ) then ("%d",lval) else ("%g",lval)
	  in		
	  let lname = getname var in
	  let lformat,exp = format_str var in
	  let str = (strpart count lname) ^ lformat ^"\n" in
		make_printf_instr [(Const(CStr(str)));exp]
    in
    let first_print = print_one_var (spprintf "%d,%s,") lhs in
	  (* need to differentiate this site from this same site visited
	   * subsequently *)
    let comparables = 
	  lflat
		(lmap
		   (fun vars ->
			  hfold 
				(fun _ -> fun vi -> fun accum ->
				   if (not (vi.vname = lname))
					 && (not (vi.vname = rname)) 
					 && (comparable (Lval(var(vi)))) then
					   (Lval(var(vi))) :: accum else accum) vars []) [local_vars;global_vars])
    in
	let lst = first_print :: (lmap (print_one_var (spprintf "*%d,%s,")) comparables) in
	  if !flush_count == !flush_interval then begin
		flush_count := 1;
		lst @ [flush_instr()]
	  end else 
		begin
		  incr flush_count;
		  lst
		end
		
  method vblock b = 
    let rec get_stmt_nums bss =
      let opts s : int list = 
		match s with
		  None -> []
		| Some(s) -> get_stmt_nums [s]
      in
		match bss with
		  [] -> []
		| bs :: bstail -> 
			let nums1 =
			  match bs.skind with
			  | If(_,b1,b2,_) ->  (get_stmt_nums b1.bstmts) @ (get_stmt_nums b2.bstmts)
			  | Loop(b1,_,sopt1,sopt2) -> (opts sopt1) @ (opts sopt2)
			  | Switch(_,b,slist,_) -> (get_stmt_nums b.bstmts) @ (get_stmt_nums slist) 
			  | Block(b) ->  get_stmt_nums b.bstmts
			  | TryFinally(b1,b2,_) ->  (get_stmt_nums b1.bstmts) @ (get_stmt_nums b2.bstmts)
			  | TryExcept(b1,_,b2,_) -> (get_stmt_nums b1.bstmts) @ (get_stmt_nums b2.bstmts)
			  | _ -> []
			in
			  (if bs.sid >= 0 then bs.sid :: nums1 else nums1) @ (get_stmt_nums bstail)
    in
      ChangeDoChildrenPost
		(b,
		 (fun b ->
			let bstmts = 
			  (* we want to replace a statement with a list of statments, where
				 the first element of the list is an Instr(ilist) of the
				 instructions for printing out the logging information and the
				 second element of the list is the original statement.  The
				 tricky bit here is when we mutate instrumented programs, right?
				 But maybe not, so long as statement ID are preserved. *)
			  lflat 
				(lmap 
				   (fun s ->
					  match s.skind with 
						If(e1,b1,b2,l) -> 
						  let thens = get_stmt_nums b1.bstmts in 
						  let elses = get_stmt_nums b2.bstmts in 
							if !do_branches then
							  let news =
								let esite = (l,s.sid,e1,!do_coverage) in
								let sinfo = (Branches(esite,thens,elses)) in
								let num,str_exp = get_next_site sinfo in
								  (*								  pprintf "branches! stmt: %d, site_num: %d, trues:" s.sid num;
																	  (liter (fun d -> pprintf "%d, " d) thens);
																	  pprintf "falses: ";
																	  (liter (fun d -> pprintf "%d, " d) elses);
																	  pprintf "\n"; flush stdout;*)
								  make_printf_instrs true [str_exp;e1]
							  in [news;s]
							else [s]
					  | Return(Some(e), l) -> 
						  let etyp = typeOf e in
						  let comparable = 
							((isPointerType etyp) || (isArrayType etyp) ||
							   (isArithmeticType etyp) || (isIntegralType etyp))  
							&& (not (isConstant e)) in
							if comparable && !do_returns then
							  let news = 
								let conds = 
								  lmap (fun cmp -> BinOp(cmp,e,zero,(TInt(IInt,[])))) [Lt;Gt;Eq] in
								let exp_and_conds = 
								  lmap 
									(fun cond -> 
									   let sinfo = (Returns(l,s.sid,e,!do_coverage)) in
									   let site_num, si = get_next_site sinfo in 
										 (si,cond)) 
									conds 
								in
								let instrs1 =
								  lmap (fun (str_exp,cond) ->
										  make_printf_instr [str_exp;cond]) exp_and_conds in
								  mkStmt(Instr(instrs1 @ (flush_instr () :: [])))
							  in [news;s]
							else if !do_coverage then begin
							  let count,_ = get_next_site (Is_visited(!currentLoc,s.sid)) in
							  let str_exp = (Const(CStr(Printf.sprintf "%d\n" count))) in
							  let new_stmt = make_printf_instrs true [str_exp] in
								[new_stmt;s]
							end else [s]
					  | Return(_) ->
						  if !do_coverage then begin
							let count,_ = get_next_site (Is_visited(!currentLoc,s.sid)) in
							let str_exp = (Const(CStr(Printf.sprintf "%d\n" count))) in
							let new_stmt = make_printf_instrs true [str_exp] in
							  [new_stmt;s]
						  end else [s]
					  | _ ->
						  if !do_coverage && (can_trace s) &&  not (hmem noIsVisited_ht s.sid) then begin
							(* get next site's returned string is unecessarily
							   complicated for the visitation instrumentation *)
							let count,_ = get_next_site (Is_visited(!currentLoc,s.sid)) in
							let str_exp = (Const(CStr(Printf.sprintf "%d\n" count))) in
							let new_stmt = make_printf_instrs true [str_exp] in
							  [new_stmt;s]
						  end else [s]) b.bstmts) in
			  {b with bstmts=bstmts}))

  method vfunc fdec = hclear local_vars; DoChildren 
    (* FIXME: don't I want to add function parameters and variable declarations
       in general to the local vars table? *)

  method vinst i = 
    if !do_sp then begin
      let ilist = 
		match i with 
		  Set((h,o), e, l) 
		| Call(Some((h,o)), e, _, l) ->
			begin
			  (match h with
				 Var(vi) -> 
				   if not vi.vglob then hrep local_vars vi.vname vi
			   | _ -> ());
			  let instr =
				(* consider this rule a gigantic heuristic for what we
				 * can handle easily. Memory locations on the left-hand
				 * side which include a field suggest a struct/value we
				 * might care about. So even if we can't resolve it to
				 * a varinfo (sadly, pointer analysis appears kind of
				 * unhelpful here), we do instrument it. Clearly this
				 * is imperfect; we'll see how much it screws us up. *)
				match (h,o) with
				  (Var(_), _) 
				| (_, Field(_)) -> true
				| _ -> false
			  in
				if instr  && ((Hashtbl.length local_vars > 0) || (Hashtbl.length global_vars > 0)) then begin
				  let num = hfind instr_cov_ht i in
				  let ps = 
					self#print_vars (Lval(h,o)) e num in
					(i :: ps)
				end else [i]
			end
		| _ -> [i] in
		ChangeTo ilist
    end else DoChildren
end

let ins_visitor = new instrumentVisitor
let num_visitor = new numVisitor

let main () = begin
  let usageMsg = "Prototype Cheap Bug Isolation Instrumentation\n" in

  let filenames = ref [] in
    (* question: if we're trying to mirror coverage.ml, should we just
       include it so that changes are consistent between files? *)

  let argDescr = [ 
    "--returns", Arg.Set do_returns, " Instrument return values.";
    "--branches", Arg.Set do_branches, " Instrument branches.";
    "--sp", Arg.Set do_sp, " Instrument scalar-pairs.";
	"--cov", Arg.Set do_coverage, " Instrument for set-intersection.";
    "--default", Arg.Set do_all, " Do all four.";
	"--interv", Arg.Set_int flush_interval, " Insert flush every X printfs.  Default: 1";
  ] in
  let handleArg str = filenames := str :: !filenames in
    Arg.parse (Arg.align argDescr) handleArg usageMsg ;

    (* sometimes the ocaml type system is inexcusably stupid. Those
       times usually involve objects *)
    let coerce iv = (iv : instrumentVisitor :> Cil.cilVisitor) in

      if !do_all then begin
		do_returns := true; do_branches := true; do_sp := true; do_coverage := true
      end;
      
      Cil.initCIL();

      List.map 
		(fun filename -> 
		   let file = Frontc.parse filename () in
			 (* the following prevents Cil from printing out the
				damned #line directives in the output. I don't know
				if the directives are useful in any way, but for the
				time being I find the output a lot more readable
				this way *)
			 Cil.lineDirectiveStyle := None;
			 Cprint.printLn := false;

			 ignore (Partial.globally_unique_vids file);
			 ignore (Cfg.computeFileCFG file);

			 (* visitCilFileSameGlobals my_every file ;*)
			 visitCilFileSameGlobals num_visitor file ; 
			 visitCilFileSameGlobals (coerce ins_visitor) file;

			 let new_global = GVarDecl(stderr_va,!currentLoc) in 
			   file.globals <- new_global :: file.globals ;
			   
			   let fd = Cil.getGlobInit file in 
			   let lhs = Cil.var(stderr_va) in
			   let data_str = file.fileName ^ ".preds" in 
			   let str_exp = Const(CStr(data_str)) in 
			   let str_exp2 = Const(CStr("wb")) in 
			   let instr = Call((Some(lhs)),fopen,[str_exp;str_exp2],!currentLoc) in 
			   let new_stmt = Cil.mkStmt (Instr[instr]) in 
				 if flush_interval != flush_count then begin
				   let flush_stmt = [mkStmt(Instr[flush_instr()])] in
					 fd.sbody.bstmts <- fd.sbody.bstmts @ flush_stmt
				 end;
				 fd.sbody.bstmts <- new_stmt :: fd.sbody.bstmts ; 

				 (****************************************************)

				 iterGlobals file (fun glob ->
									 dumpGlobal defaultCilPrinter stdout glob ;
								  ) ; 
				 let sites = file.fileName ^ ".sites" in
				 let fout = open_out_bin sites in
				   Marshal.to_channel fout file [] ;
				   Marshal.to_channel fout !coverage_ht [] ;
				   Marshal.to_channel fout (!count - 1) [] ;
				   Marshal.to_channel fout !site_ht [] ;
				   Marshal.to_channel fout !site [] ;
				   close_out fout;
		) !filenames;
      
end ;;

main () ;;
    