(* 
 * Program Repair Prototype (v2) 
 *
 * Search Strategies include: 
 *  -> Brute Force (e.g., all distance-one edits)
 *  -> Genetic Programming (e.g., ICSE'09)
 *     => delete, append and swap based on fault localization
 *     => crossover: none, one point, two point, uniform, ...
 *)
open Printf
open Global
open Fitness
open Rep
open List

let weight_compare (stmt,prob) (stmt',prob') =
    if prob = prob' then compare stmt stmt' 
    else compare prob' prob 

(*************************************************************************
 *************************************************************************
                          Generate Variants
		(like Brute Force, but different)
 *************************************************************************
 *************************************************************************)

exception FoundEnough 

let generate_variants (original : Rep.representation) incoming_pop variants_per_distance distance =
  debug "search: Generate variants\n" ;
  let fault_localization = original#get_fault_localization () in 
  let fix_localization = original#get_fix_localization () in
  let _ = Random.self_init() in

    debug "Length fault: %d length fix: %d\n" (length fault_localization) (length fix_localization);
  let random x1 x2 = 
    let rand = Random.int 10 in 
      if rand > 5 then -1 else if rand < 5 then 1 else 0
  in
  let randomize worklist = sort random worklist in
    (*  let remove local_list atom = filter (fun (x,_) -> not (x = atom)) local_list in*)

  let worklist = ref [] in 
    (* first, try all single edits *) 

  let in_ops ops (op_str,op_atom1,op_atom2) = 
    try
      let _ = find (fun (str,atom1,atom2) -> str = op_str && atom1 = op_atom1 && atom2 = op_atom2) ops in
	true
    with Not_found -> false
  in

  let choose lst num =
    let rec inner_choose lst count =
      if (length lst) = 0 then [] else 
	if count = 0 then [] else
	  (hd lst) :: (inner_choose (tl lst) (count - 1))
    in
      inner_choose lst num
  in
  let rec generate_all_permutations num_ops accum =
    debug "Generating combination %d. Accum length %d\n" num_ops (length accum);
    if num_ops = 0 then accum else
      let add_another_delete = ref [] in
	iter (fun current_ops -> 
		(iter (fun (atom,_) -> 
			 if not (in_ops current_ops ("d",atom,0)) then
			   add_another_delete := (("d",atom,0) :: current_ops) :: !add_another_delete
		      ) (choose (randomize fault_localization) 100))) accum;
	debug "length add another delete: %d\n" (length !add_another_delete);
      let add_another_append = ref [] in
	iter (fun current_ops ->
		iter (fun(src,_) ->
			iter(fun (dest,_) ->
			       if not (in_ops current_ops ("a",dest,src)) then
				 add_another_append := (("a",src,dest) :: current_ops) :: !add_another_append)
			  (choose (randomize fix_localization) 100))
		  (choose (randomize fault_localization) 100)) accum;
	debug "length add another append: %d\n" (length !add_another_append);
      let final_list =  (choose ((!add_another_delete)@(!add_another_append)) 10000) in
	debug "Length of final list is %d\n" (length final_list);
	generate_all_permutations (num_ops - 1) final_list
  in 
    (* you need to make a set of one ops for generate_all_permutations to work on *)
  let initial_dels = map (fun(atom,_) -> [("d",atom,0)]) fault_localization in
  let initial_apps = ref [] in
    iter(fun (dest,w1) ->
	   iter (fun(src,w2) ->
		   if dest<> src then initial_apps := [("a",dest,src)] :: !initial_apps) fix_localization)
      fault_localization;
    let initial_pop = initial_dels @ !initial_apps in
		     debug "Length initial pop is %d\n" (length initial_pop);

  let op_worklist = generate_all_permutations (distance - 1) (choose initial_pop 100) in
  let worklist = ref [] in
    iter (fun op_list ->  
	    let thunk() =
	      fold_left 
		(fun rep -> 
		   fun(str,atom1,atom2) ->
		     match str with
			 "d" -> rep#delete atom1; rep
		       | "a" -> rep#append atom1 atom2; rep
		) (original#copy()) op_list
	    in
	      worklist := (thunk,1.0) :: !worklist 
	 ) op_worklist;

    let worklist = randomize !worklist in 
      begin
	try 
	  let sofar = ref 1 in
	  let howmany = length worklist in
	  let found_adequate = ref 0 in 
	    iter
	      (fun (thunk,w) ->
		 if !found_adequate = variants_per_distance then
		   raise (FoundEnough)
		 else begin
		   debug "\tvariant %d/%d\n" !sofar howmany ;
		   let rep = thunk() in
		     incr sofar; 
		     if (check_for_generate rep) then incr found_adequate
		 end
	      )
	      worklist
	with FoundEnough -> ()
      end;
      debug "search: generate_variants ends";
      [] 
  
(*************************************************************************
 *************************************************************************
                     Brute Force: Try All Single Edits
 *************************************************************************
 *************************************************************************)

let brute_force_1 (original : Rep.representation) incoming_pop = 
  debug "search: brute_force_1 begins\n" ; 
  if incoming_pop <> [] then begin
    debug "search: incoming population IGNORED\n" ; 
  end ; 
  let fault_localization = original#get_fault_localization () in 
  let fault_localization = List.sort weight_compare fault_localization in 
  let fix_localization = original#get_fix_localization () in 
  let fix_localization = List.sort weight_compare fix_localization in 

  let worklist = ref [] in 

  (* first, try all single deletions *) 
  List.iter (fun (atom,weight) ->
    (* As an optimization, rather than explicitly generating the
     * entire variant in advance, we generate a "thunk" (or "future",
     * or "promise") to create it later. This is handy because there
     * might be over 100,000 possible variants, and we want to sort
     * them by weight before we actually instantiate them. *) 
    let thunk () = 
      let rep = original#copy () in 
      rep#delete atom; 
      rep
    in 
    worklist := (thunk,weight) :: !worklist ; 
  ) fault_localization ; 


    (* second, try all single appends *) 
  List.iter (fun (dest,w1) ->
    List.iter (fun (src,w2) -> 
      let thunk () = 
        let rep = original#copy () in 
        rep#append dest src; 
        rep 
      in 
      worklist := (thunk, w1 *. w2 *. 0.9) :: !worklist ; 
    ) fix_localization 
  ) fault_localization ;  

  (* third, try all single swaps *) 
  List.iter (fun (dest,w1) ->
    List.iter (fun (src,w2) -> 
      if dest <> src then begin (* swap X with X = no-op *) 
        let thunk () = 
          let rep = original#copy () in 
          rep#swap dest src;
          rep
        in 
        worklist := (thunk, w1 *. w2 *. 0.8) :: !worklist ; 
      end 
    ) fault_localization 
  ) fault_localization ;  

  let worklist = List.sort 
    (fun (m,w) (m',w') -> compare w' w) !worklist in 
  let howmany = List.length worklist in 
  let sofar = ref 1 in 
  List.iter (fun (thunk,w) ->
    debug "\tvariant %d/%d (weight %g)\n" !sofar howmany w ;
    let rep = thunk () in 
    incr sofar ;
    test_to_first_failure rep 
  ) worklist ; 

  debug "search: brute_force_1 ends\n" ; 
  [] 


(*************************************************************************
 *************************************************************************
                          Basic Genetic Algorithm
 *************************************************************************
 *************************************************************************)

let generations = ref 10
let popsize = ref 40 
let _ = 
  options := !options @ [
  "--generations", Arg.Set_int generations, "X use X genetic algorithm generations";
  "--popsize", Arg.Set_int popsize, "X variant population size";
] 

(***********************************************************************
 * Weighted Micro-Mutation
 *
 * Here we pick delete, append or swap, and then apply that atomic operator
 * once to a location chosen based on the fault localization information.
 ***********************************************************************)

let mutate (variant : Rep.representation) fault_location fix_location = 
  let result = variant#copy () in 
  (match Random.int 3 with
  | 0 -> result#delete (fault_location ())  
  | 1 -> result#append (fault_location ()) (fix_location ()) 
  | _ -> result#swap (fault_location ()) (fix_location ()) 
  ) ;
  result 


(***********************************************************************
 * Tournament Selection
 ***********************************************************************)
let tournament_k = ref 2 
let tournament_p = ref 1.00 

let tournament_selection (population : (representation * float) list) 
           (desired : int) 
           (* returns *) : representation list = 
  let p = !tournament_p in 
  assert ( desired >= 0 ) ; 
  assert ( !tournament_k >= 1 ) ; 
  assert ( p >= 0.0 ) ; 
  assert ( p <= 1.0 ) ; 
  assert ( List.length population > 0 ) ; 
  let rec select_one () = 
    (* choose k individuals at random *) 
    let lst = random_order population in 
    (* sort them *) 
    let pool = first_nth lst !tournament_k in 
    let sorted = List.sort (fun (_,f) (_,f') -> compare f' f) pool in 
    let rec walk lst step = match lst with
    | [] -> select_one () 
    | (indiv,fit) :: rest -> 
        let taken = 
          if p >= 1.0 then true
          else begin 
            let required_prob = p *. ((1.0 -. p)**(step)) in 
            Random.float 1.0 <= required_prob 
          end 
        in
        if taken then (indiv) else walk rest (step +. 1.0)
    in
    walk sorted 0.0
  in 
  let answer = ref [] in 
  for i = 1 to desired do
    answer := (select_one ()) :: !answer
  done ;
  !answer

(* Selection -- currently we have only tournament selection implemented,
 * but if/when we add others, we choose between them here. *)  
let selection (population : (representation * float) list) 
           (desired : int) 
           (* returns *) : representation list = 
  tournament_selection population desired 

(***********************************************************************
 * Basic Genetic Algorithm Search Strategy
 *
 * This is parametric with respect to a number of choices (e.g.,
 * population size, selection method, fitness function, fault
 * localization, ...). 
 ***********************************************************************)
let genetic_algorithm (original : Rep.representation) incoming_pop = 
  debug "search: genetic algorithm begins\n" ; 
  let fault_localization = original#get_fault_localization () in 
  let fault_localization = List.sort weight_compare fault_localization in 
  let fix_localization = original#get_fix_localization () in 
  let fix_localization = List.sort weight_compare fix_localization in 
  let fault_localization_total_weight = 
    List.fold_left (fun acc (_,prob) -> acc +. prob) 0. fault_localization 
  in 
  let rec choose_from_weighted_list chosen_index lst = match lst with
  | [] -> failwith "localization error"  
  | (sid,prob) :: tl -> if chosen_index <= prob then sid
                  else choose_from_weighted_list (chosen_index -. prob) tl
  in 
  (* choose a stmt weighted by the localization *) 
  let fault () = choose_from_weighted_list 
      (Random.float fault_localization_total_weight) fault_localization
  in
  (* choose a stmt uniformly at random *) 
  let random () = 
    1 + (Random.int (original#max_atom ()) )
  in
  (* transform a list of variants into a listed of fitness-evaluated
   * variants *) 
  let calculate_fitness pop = 
    List.map (fun variant -> (variant, test_all_fitness variant)) pop
  in 

  let pop = ref [] in (* our GP population *) 
  for i = 1 to pred !popsize do
    (* initialize the population to a bunch of random mutants *) 
    pop := (mutate original fault random) :: !pop 
  done ;
  (* include the original in the starting population *)
  pop := (original#copy ()) :: !pop ;

  (* Main GP Loop: *) 
  for gen = 1 to !generations do
    debug "search: generation %d\n" gen ; 
    (* Step 1. Calculate fitness. *) 
    let incoming_population = calculate_fitness !pop in 
    let offspring = ref [] in 
    (* Step 2. Select individuals for crossover/mutation *)
    for i = 1 to !popsize do
      match selection incoming_population 1 with
      | [one] -> offspring := (mutate one fault random) :: !offspring
      | _ -> failwith "selection error" 
    done ;
    (* Step 3. TODO: Should include crossover *) 
    let offspring = calculate_fitness !offspring in 
    (* Step 4. Select the best individuals for the next generation *) 
    pop := selection (incoming_population @ offspring) !popsize 
  done ;
  debug "search: genetic algorithm ends\n" ;
  !pop 
