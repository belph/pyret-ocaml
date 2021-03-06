open CompileStructs
open PyretUtils

module A = Ast
module SD = StringDict
module W = WellFormed
module D = Desugar
module CH = DesugarCheck
module AU = AstUtils

type pyret_code =
    PyretString of string
  | PyretAst of A.program

type loadable =
    ModuleAsString of Provides.t * CompileEnvironment.t
                      * Codegen.Js.OfPyret.compiled_code_printer CompileResult.t
  (* Until I actually understand how best to do builtin modules, this remains commented out.
     | PreLoaded of Provides.t * CompileEnvironment.t * 'a*)

type provides = Provides.t

type locator = {
  (** Could either have needs_provide be implicitly stateful, and cache the most
      recent map, or use explicit interface below *)
  needs_compile : provides SD.t -> bool;

  (** Pre-compile (skippable if get-compile returns something) *)
  get_module : unit -> pyret_code;

  (** Pre-compile (had better be known with no other help) *)
  get_dependencies : unit -> Dependency.t list;

  (** Pre-compile *)
  get_extra_imports : unit -> ExtraImports.t;

  (** Pre-compile, specification of available globals *)
  get_globals : unit -> Globals.t;

  (** Post-compile, on-run (maybe dynamic and new namespace) *)
  get_namespace : unit -> unit; (* FIXME: Missing R.Runtime.t and N.Namespace.t *)

  (** Returns this locator's URI *)
  uri : unit -> uri;

  (** Returns this locator's name *)
  name : unit -> string;

  (** TODO: Figure out what this does *)
  set_compiled : loadable -> Provides.t SD.t -> unit;

  (** Pre-compile if needs-compile is false *)
  get_compiled : unit -> loadable option;

  (** Should compare uris for locators *)
  _equals : locator -> locator -> bool;
}

and 'a located = Located of locator * 'a

type to_compile = {
  locator : locator;
  dependency_map : locator MutableStringDict.t;
  path : to_compile list;
}

type compiled_program = {
  loadables : loadable list;
  modules : loadable MutableStringDict.t
}

type load_info = {
  to_compile : to_compile;
  compiled_mod : loadable
}

let get_ast (p : pyret_code) (uri : uri) =
  match p with
  | PyretString(s) -> failwith "NYI" (* TODO: Implement ParsePyret module *)
  | PyretAst(a) -> a

let get_import_type i =
  let open Ast in
  match i with
  | SImport(_, f, _)
  | SImportTypes(_, f, _, _)
  | SInclude(_, f)
  | SImportComplete(_, _, _, f, _, _)
  | SImportFields(_, _, f) -> f

let get_dependencies (p : pyret_code) (uri : uri) =
  let parsed = get_ast p uri in
  match parsed with
  | Ast.SProgram(_, _, _, imports, _) ->
    List.map (fun i -> AU.import_to_dep @@ get_import_type i) imports

let get_standard_dependencies (p : pyret_code) (uri : uri) : Dependency.t list =
  let mod_deps = get_dependencies p uri in
  mod_deps @ ExtraImports.dependencies standard_imports

let string_locator (uri : uri) (s : string) =
  {
    needs_compile = (fun _ -> true);
    get_module = (fun () -> PyretString(s));
    get_dependencies = (fun () -> get_standard_dependencies (PyretString(s)) uri);
    get_extra_imports = (fun () -> standard_imports);
    get_globals = (fun () -> standard_globals);
    get_namespace = (fun () -> failwith "NYI");
    uri = (fun () -> uri);
    name = (fun () -> uri);
    set_compiled = (fun _ _ -> ());
    get_compiled = (fun () -> None);
    _equals = (fun self other -> (self.uri()) = (other.uri()))
  }

let const_dict : 'a. string list -> 'a -> 'a SD.t = fun strs value ->
  List.fold_left (fun d s -> SD.add s value d) SD.empty strs

let dict_map : 'a 'b. 'a MutableStringDict.t -> (string -> 'a -> 'b) -> 'b SD.t =
  fun msd f ->
    let open MutableStringDict in
    List.fold_left(fun sd2 (k,v) ->
        SD.add k (f k v) sd2) SD.empty (bindings msd)

let dummy_provides uri =
  Provides.Provides(uri, SD.empty, SD.empty, SD.empty)

let compile_worklist : 'a. ('a -> Dependency.t -> 'a located) -> locator -> 'a -> to_compile list =
  fun dfind locator context ->
    let rec add_preds_to_worklist locator context curr_path =
      let _ =
        let res = list_find (fun tc -> tc.locator = locator) curr_path in
        if (match res with | Some(_) -> true | None -> false) then
          failwith @@ "Detected module cycle: " ^
          (join_str (List.map (fun a -> a.locator.uri()) curr_path) ", ") in
      let open MutableStringDict in
      let pmap = create 30 in
      let deps = locator.get_dependencies() in
      let found_mods =
        let mapfun = fun d ->
          let found = dfind context d in
          match found with
          | Located(locator,_) ->
            add pmap (Dependency.key d) locator;
            found in
        List.map mapfun deps in
      let tocomp = { locator = locator; dependency_map = pmap; path = curr_path } in
      let foldfun ret = function
        | Located(locator, context) ->
          let pret = add_preds_to_worklist locator context @@ curr_path @ [tocomp] in
        pret @ ret in
      List.fold_left foldfun [tocomp] found_mods in
    add_preds_to_worklist locator context []

let rec compile_program_with (worklist : to_compile list) modules options =
  let cache = modules in
  let loadables =
    let mapfun w =
      let uri = w.locator.uri() in
      if not (MutableStringDict.mem cache uri) then
        begin
        let provide_map = dict_map w.dependency_map
            (fun _ v ->
               match MutableStringDict.find cache (v.uri()) with
               | ModuleAsString(provides,_,_) -> provides) in
        let loadable = compile_module w.locator provide_map cache options in
        MutableStringDict.add cache uri loadable;
        loadable
        end
      else
        MutableStringDict.find cache uri in
    List.map mapfun worklist in
  { loadables = loadables; modules = cache }

and compile_program worklist options =
  compile_program_with worklist (MutableStringDict.create 30) options

and compile_module locator provide_map modules options =
  if locator.needs_compile provide_map then
    begin
      let open CompileResult in
      let open Compile.CompilationPhase in
      let env = CompileEnvironment.CompileEnvironment(locator.get_globals(), provide_map) in
      let libs = locator.get_extra_imports() in
      let _module = locator.get_module() in
      let ast =
        match _module with
        | PyretString(module_string) -> failwith "NYI: compile_module PyretString"
        | PyretAst(module_ast) -> module_ast in
      let ret = ref Start in
      let set_phase str fmt v =
        if options.collect_all then
          ret := Phase(str, (fun () -> fmt v), !ret) in
      let ssexp : 'a. ('a -> Sexplib.Sexp.t) -> 'a -> string =
        fun fmt v -> Sexplib.Sexp.to_string_hum (fmt v) in
      let ast_ended = AstUtils.append_nothing_if_necessary ast in
      (match ast_ended with
       | None -> ()
       | Some(v) -> set_phase "Added nothing" (ssexp Ast.sexp_of_program) v);
      let wf = WellFormed.check_well_formed @@ Option.map_default (fun x -> x) ast ast_ended in
      set_phase "Checked well-formedness" (ssexp @@ CompileResult.sexp_of_t Ast.sexp_of_program) wf;
      let checker =
        if options.check_mode then DesugarCheck.desugar_check
        else DesugarCheck.desugar_no_checks in
      match wf with
      | Ok(wf_ast) ->
        begin
          let checked = checker wf_ast in
          let imported = AstUtils.wrap_extra_imports checked libs in
          let scoped = ResolveScope.desugar_scope imported env in
          let named_result = ResolveScope.resolve_names scoped env in
          let named_ast, named_errors =
            match named_result with
            | NameResolution.Resolved(ast, errs, _, _, _) -> ast, errs in
          let provides = AstUtils.get_named_provides named_result (locator.uri()) env in
          let desugared = Desugar.desugar named_ast in
          let type_checked =
            if options.type_check then
              failwith "Type-checking not yet implemented"
            else
              Ok(desugared) in
          match type_checked with
          | Ok(tc_ast) ->
            let any_errors = named_errors
                             @ (AstUtils.check_unbound env tc_ast)
                             @ (AstUtils.bad_assignments env tc_ast) in
            let dp_ast = tc_ast (* TODO: Post-desugar type-checking *) in
            let cleaned =
              dp_ast
              |> (new AstUtils.merge_nested_blocks)#visit_program
              |> (new AstUtils.flatten_single_blocks)#visit_program
              |> (new AstUtils.link_list_visitor env)#visit_program
              |> (new AstUtils.letrec_visitor)#visit_program in
            let inlined = (new AstUtils.inline_lams)#visit_program cleaned in
            let cr =
              match any_errors with
              | [] -> Ok(Codegen.Js.OfPyret.make_compiled_pyret inlined env options)
              | _ -> Err(any_errors) in
            let mod_result = ModuleAsString(provides, env, cr) in
            locator.set_compiled mod_result provide_map;
            mod_result
          | Err(_) -> failwith "Impossible"
        end
      | Err(_) -> ModuleAsString(dummy_provides (locator.uri()), env, failwith "FIXME: wf")
    end
  else
    match locator.get_compiled() with
    | None -> failwith @@ "No precompiled module found for " ^ (locator.uri())
    | Some(v) -> v

let rec compile_and_run_worklist_with (ws : to_compile list) runtime initial options =
  let compiled_mods = (compile_program_with ws initial options).loadables in
  let errors =
    compiled_mods
    |> List.filter is_error_compilation in
  match errors with
  | [] ->
    let load_infos = List.map2 (fun tc cm -> { to_compile = tc; compiled_mod = cm })
        ws compiled_mods in
    Either.Right(load_worklist load_infos SD.empty (failwith "L.make-loader(runtime)") runtime)
  | _ ->
    Either.Left(List.map (function
        | ModuleAsString(_, _, rp) -> rp
        | _ -> failwith "Impossible: Non-ModuleAsString's filtered out") errors)

and compile_and_run_worklist ws runtime options =
  compile_and_run_worklist_with ws runtime (MutableStringDict.create 50) options

and is_error_compilation = function
  | ModuleAsString(_, _, CompileResult.Err(_)) -> true
  | _ -> false

and run_program ws prog runtime options = failwith "NYI: run_program"

and load_worklist ws modvals loader runtime =
  let open CompileResult in
  match ws with
  | [] ->
    failwith "Didn't get anything to run in load_worklist"
  | load_info :: tl ->
    let depmap = load_info.to_compile.dependency_map in
    let dependencies = load_info.to_compile.locator.get_dependencies() in
    let depnames = List.map (Dependency.key) dependencies in
    let get_depmap_uri d =
      let depmapval = MutableStringDict.find depmap d in
      depmapval.uri() in
    let depvals = List.map (fun d ->
        { modval = StringDict.find modvals @@ get_depmap_uri d; key = d }) depnames in
    let m = load_info.compiled_mod in
    (match m with
     | ModuleAsString(_, _, Err(problems)) ->
       (* FIXME: Should be semantically similar to `raise(m.result-printer.problems)'*)
       ValueSkeleton.of_list CompileError.to_vs problems ()
       |> ValueSkeleton.render
       |> failwith
     | _ -> ());
    let ans = loader.load m depvals (load_info.to_compile.locator.get_namespace(runtime)) in
    let modvals_new = StringDict.add (load_info.to_compile.locator.uri()) ans modvals in
    let answer = loader.run ans m (load_info.to_compile.locator.uri()) in
    match tl with
    | [] -> answer
    | _ -> load_worklist tl modvals_new loader runtime

and compile_and_run_locator locator finder context runtime options =
  let wl = compile_worklist finder locator context in
  compile_and_run_worklist wl runtime options
